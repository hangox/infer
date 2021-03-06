(*
 * Copyright (c) 2017 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! IStd
module F = Format
module L = Logging

(** Forward analysis to compute uninitialized variables at each program point *)
module D =
UninitDomain.Domain
module UninitVars = AbstractDomain.FiniteSet (AccessPath)
module AliasedVars = AbstractDomain.FiniteSet (UninitDomain.VarPair)
module PrePost = AbstractDomain.Pair (D) (D)
module RecordDomain = UninitDomain.Record (UninitVars) (AliasedVars) (D)

module Summary = Summary.Make (struct
  type payload = UninitDomain.summary

  let update_payload sum (summary: Specs.summary) =
    {summary with payload= {summary.payload with uninit= Some sum}}


  let read_payload (summary: Specs.summary) = summary.payload.uninit
end)

let intraprocedural_only = true

let blacklisted_functions = [BuiltinDecl.__set_array_length]

let is_type_pointer t = match t.Typ.desc with Typ.Tptr _ -> true | _ -> false

let rec is_basic_type t =
  match t.Typ.desc with
  | Tint _ | Tfloat _ | Tvoid ->
      true
  | Tptr (t', _) ->
      is_basic_type t'
  | _ ->
      false


let is_blacklisted_function pname =
  List.exists ~f:(fun fname -> Typ.Procname.equal pname fname) blacklisted_functions


module TransferFunctions (CFG : ProcCfg.S) = struct
  module CFG = CFG
  module Domain = RecordDomain

  let report ap loc summary =
    let message = F.asprintf "The value read from %a was never initialized" AccessPath.pp ap in
    let ltr = [Errlog.make_trace_element 0 loc "" []] in
    let exn =
      Exceptions.Checkers (IssueType.uninitialized_value, Localise.verbatim_desc message)
    in
    Reporting.log_error summary ~loc ~ltr exn


  type extras = FormalMap.t * Specs.summary

  let should_report_var pdesc tenv uninit_vars ap =
    match (AccessPath.get_typ ap tenv, ap) with
    | Some typ, ((Var.ProgramVar pv, _), _) ->
        not (Pvar.is_frontend_tmp pv) && not (Procdesc.is_captured_var pdesc pv)
        && D.mem ap uninit_vars && is_basic_type typ
    | _, _ ->
        false


  let report_on_function_params pdesc tenv uninit_vars actuals loc extras =
    List.iter
      ~f:(fun e ->
        match e with
        | HilExp.AccessPath ((var, t), al)
          when should_report_var pdesc tenv uninit_vars ((var, t), al) && not (is_type_pointer t) ->
            report ((var, t), al) loc (snd extras)
        | _ ->
            ())
      actuals


  let remove_fields tenv base uninit_vars =
    match base with
    | _, {Typ.desc= Tptr ({Typ.desc= Tstruct name_struct}, _)} | _, {Typ.desc= Tstruct name_struct}
          -> (
      match Tenv.lookup tenv name_struct with
      | Some {fields} ->
          List.fold
            ~f:(fun acc (fn, _, _) -> D.remove (base, [AccessPath.FieldAccess fn]) acc)
            fields ~init:uninit_vars
      | _ ->
          uninit_vars )
    | _ ->
        uninit_vars


  let get_formals call =
    match Ondemand.get_proc_desc call with
    | Some proc_desc ->
        Procdesc.get_formals proc_desc
    | _ ->
        []


  let is_struct t = match Typ.name t with Some _ -> true | _ -> false

  let function_expect_a_pointer call idx =
    let formals = get_formals call in
    match List.nth formals idx with Some (_, typ) -> is_type_pointer typ | _ -> false


  let is_dummy_constructor_of_a_struct call =
    let is_dummy_constructor_of_struct =
      match get_formals call with
      | [(_, {Typ.desc= Typ.Tptr ({Typ.desc= Tstruct _}, _)})] ->
          true
      | _ ->
          false
    in
    Typ.Procname.is_constructor call && is_dummy_constructor_of_struct


  let exec_instr (astate: Domain.astate) {ProcData.pdesc; ProcData.extras; ProcData.tenv} _
      (instr: HilInstr.t) =
    match instr with
    | Assign
        ( (((lhs_var, lhs_typ), apl) as lhs_ap)
        , HilExp.AccessPath (((_, rhs_typ) as rhs_base), al)
        , loc ) ->
        let uninit_vars' = D.remove lhs_ap astate.uninit_vars in
        let uninit_vars =
          if Int.equal (List.length apl) 0 then
            (* if we assign to the root of a struct then we need to remove all the fields *)
            remove_fields tenv (lhs_var, lhs_typ) uninit_vars'
          else uninit_vars'
        in
        let prepost =
          if FormalMap.is_formal rhs_base (fst extras)
             && match rhs_typ.desc with Typ.Tptr _ -> true | _ -> false
          then
            let pre' = D.add (rhs_base, al) (fst astate.prepost) in
            let post = snd astate.prepost in
            (pre', post)
          else astate.prepost
        in
        (* check on lhs_typ to avoid false positive when assigning a pointer to another *)
        if should_report_var pdesc tenv uninit_vars (rhs_base, al) && not (is_type_pointer lhs_typ)
        then report (rhs_base, al) loc (snd extras) ;
        {astate with uninit_vars; prepost}
    | Assign (lhs, _, _) ->
        let uninit_vars = D.remove lhs astate.uninit_vars in
        {astate with uninit_vars}
    | Call (_, Direct callee_pname, _, _, _)
      when Typ.Procname.equal callee_pname BuiltinDecl.objc_cpp_throw ->
        {astate with uninit_vars= D.empty}
    | Call (_, HilInstr.Direct call, _, _, _) when is_dummy_constructor_of_a_struct call ->
        astate
    | Call (_, HilInstr.Direct call, actuals, _, loc) ->
        (* in case of intraprocedural only analysis we assume that parameters passed by reference
           to a function will be initialized inside that function *)
        let uninit_vars =
          List.foldi
            ~f:(fun idx acc actual_exp ->
              match actual_exp with
              | HilExp.AccessPath (((_, {Typ.desc= Tarray _}) as base), al)
                when is_blacklisted_function call ->
                  D.remove (base, al) acc
              | HilExp.AccessPath (((_, t) as base), al)
                when is_struct t && List.length al > 0 && function_expect_a_pointer call idx ->
                  (* Access to a field of a struct by reference *)
                  D.remove (base, al) acc
              | HilExp.AccessPath ap when Typ.Procname.is_constructor call ->
                  remove_fields tenv (fst ap) (D.remove ap acc)
              | HilExp.AccessPath (((_, {Typ.desc= Tptr _}) as base), al) ->
                  let acc' = D.remove (base, al) acc in
                  remove_fields tenv base acc'
              | HilExp.Closure (_, apl) ->
                  (* remove the captured variables of a block/lambda *)
                  List.fold ~f:(fun acc' (base, _) -> D.remove (base, []) acc') ~init:acc apl
              | _ ->
                  acc)
            ~init:astate.uninit_vars actuals
        in
        report_on_function_params pdesc tenv uninit_vars actuals loc extras ;
        {astate with uninit_vars}
    | Call _ | Assume _ ->
        astate

end

module CFG = ProcCfg.OneInstrPerNode (ProcCfg.Normal)
module Analyzer =
  AbstractInterpreter.Make (CFG) (LowerHil.Make (TransferFunctions) (LowerHil.DefaultConfig))

let get_locals cfg tenv pdesc =
  List.fold
    ~f:(fun acc (var_data: ProcAttributes.var_data) ->
      let pvar = Pvar.mk var_data.name (Procdesc.get_proc_name pdesc) in
      let base_ap = ((Var.of_pvar pvar, var_data.typ), []) in
      match var_data.typ.Typ.desc with
      | Typ.Tstruct qual_name -> (
        match Tenv.lookup tenv qual_name with
        | Some {fields} ->
            let flist =
              List.fold
                ~f:(fun acc' (fn, _, _) -> (fst base_ap, [AccessPath.FieldAccess fn]) :: acc')
                ~init:acc fields
            in
            base_ap :: flist
            (* for struct we take the struct address, and the access_path
                                    to the fields one level down *)
        | _ ->
            acc )
      | Typ.Tarray (t', _, _) ->
          (fst base_ap, [AccessPath.ArrayAccess (t', [])]) :: acc
      | _ ->
          base_ap :: acc)
    ~init:[] (Procdesc.get_locals cfg)


let checker {Callbacks.tenv; summary; proc_desc} : Specs.summary =
  let cfg = CFG.from_pdesc proc_desc in
  (* start with empty set of uninit local vars and  empty set of init formal params *)
  let formal_map = FormalMap.make proc_desc in
  let uninit_vars = get_locals cfg tenv proc_desc in
  let init =
    ( { RecordDomain.uninit_vars= UninitVars.of_list uninit_vars
      ; RecordDomain.aliased_vars= AliasedVars.empty
      ; RecordDomain.prepost= (D.empty, D.empty) }
    , IdAccessPathMapDomain.empty )
  in
  let invariant_map =
    Analyzer.exec_cfg cfg
      (ProcData.make proc_desc tenv (formal_map, summary))
      ~initial:init ~debug:false
  in
  match Analyzer.extract_post (CFG.id (CFG.exit_node cfg)) invariant_map with
  | Some
      ( {RecordDomain.uninit_vars= _; RecordDomain.aliased_vars= _; RecordDomain.prepost= pre, post}
      , _ ) ->
      Summary.update_summary {pre; post} summary
  | None ->
      if Procdesc.Node.get_succs (Procdesc.get_start_node proc_desc) <> [] then (
        L.internal_error "Uninit analyzer failed to compute post for %a" Typ.Procname.pp
          (Procdesc.get_proc_name proc_desc) ;
        summary )
      else summary
