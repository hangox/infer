/*
 * Copyright (c) 2017 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */
#import <Foundation/Foundation.h>

int* __nullable returnsNull();

@interface T : NSObject
- (NSObject* _Nullable)nullableMethod;
@end

@implementation T {
  int* unnanotatedField;
  int* __nullable nullableField;
  int* nonnullField;
}

- (void)assignNullableFieldToNullOkay {
  nullableField = nil;
}

- (void)assignUnnanotatedFieldToNullBad {
  unnanotatedField = nil;
}

- (void)assignNonnullFieldToNullBad {
  nonnullField = nil;
}

- (void)testNullableFieldForNullOkay {
  if (nullableField == nil) {
  }
}

- (void)testUnnanotatedFieldForNullBad {
  if (unnanotatedField == nil) {
  }
}

- (int)DeadStoreFP_testUnnanotatedFieldInClosureBad {
  int (^testField)(int defaultValue);
  testField = ^(int defaultValue) {
    if (unnanotatedField != nil) {
      return *unnanotatedField;
    } else {
      return defaultValue;
    }
  };
  return testField(42);
}

- (void)testNonnullFieldForNullBad {
  if (nonnullField == nil) {
  }
}

- (void)dereferenceUnnanotatedFieldOkay {
  *unnanotatedField = 42;
}

- (void)dereferenceNonnullFieldOkay {
  *nonnullField = 42;
}

- (void)dereferenceNullableFieldBad {
  *nullableField = 42;
}

- (void)dereferenceUnnanotatedFieldAfterTestForNullBad {
  if (unnanotatedField == nil) {
    *unnanotatedField = 42;
  }
}

- (void)FP_dereferenceNonnullFieldAfterTestForNullOkay {
  if (nonnullField == nil) {
    *nonnullField = 42;
  }
}

- (void)dereferenceNullableFunctionBad {
  int* p = returnsNull();
  *p = 42;
}

- (void)dereferenceNullableFunction1Ok {
  int* p = returnsNull();
  if (p) {
    *p = 42;
  }
}

- (void)dereferenceNullableFunction2Ok {
  int* p = returnsNull();
  if (p != nil) {
    *p = 42;
  }
}

- (NSObject* _Nullable)nullableMethod {
  return nil;
}

- (NSString*)dereferenceNullableMethodOkay {
  NSObject* nullableObject = [self nullableMethod];
  return [nullableObject description]; // does not report here
}

- (void)reassigningNullableObjectOkay {
  NSObject* nullableObject = [self nullableMethod];
  nullableObject = nil; // does not report here
}

- (NSArray*)nullableObjectInNSArrayBad {
  NSObject* nullableObject = [self nullableMethod];
  NSArray* array = @[ nullableObject ]; // reports here
  return array;
}

- (NSArray*)secondElementNullableObjectInNSArrayBad {
  NSObject* allocatedObject = [NSObject alloc];
  NSObject* nullableObject = [self nullableMethod];
  NSArray* array = @[ allocatedObject, nullableObject ]; // reports here
  return array;
}

- (NSArray*)nullableObjectInNSArrayOkay {
  NSObject* nullableObject = [self nullableMethod];
  NSArray* array;
  if (nullableObject) {
    array = @[ nullableObject ]; // reports here
  } else {
    array = @[ @"String" ];
  }
  return array;
}

- (NSArray*)URLWithStringOkay {
  NSURL* url = [NSURL URLWithString:@"some/url/string"];
  NSArray* array = @[ url ]; // reports here
}

- (NSDictionary*)nullableValueInNSDictionaryBad {
  NSObject* nullableValue = [self nullableMethod];
  NSMutableDictionary* dict = [NSMutableDictionary
      dictionaryWithObjectsAndKeys:@"key", nullableValue, nil]; // reports here
  return dict;
}

- (NSDictionary*)nullableKeyInNSDictionaryBad {
  NSObject* nullableKey = [self nullableMethod];
  NSMutableDictionary* dict = [NSMutableDictionary
      dictionaryWithObjectsAndKeys:nullableKey, @"value", nil]; // reports here
  return dict;
}

- (NSDictionary*)nullableKeyInNSDictionaryInitBad {
  NSObject* nullableKey = [self nullableMethod];
  NSDictionary* dict = [[NSDictionary alloc]
      initWithObjectsAndKeys:nullableKey, @"value", nil]; // reports here
  return dict;
}

- (NSDictionary*)nullableValueInNSDictionaryInitBad {
  NSObject* nullableValue = [self nullableMethod];
  NSDictionary* dict = [[NSDictionary alloc]
      initWithObjectsAndKeys:@"key", nullableValue, nil]; // reports here
  return dict;
}

- (NSDictionary*)nullableKeyInNSDictionaryInitLiteralBad {
  NSObject* nullableKey = [self nullableMethod];
  NSDictionary* dict = @{nullableKey : @"value"}; // reports here
  return dict;
}

- (NSDictionary*)nullableValueInNSDictionaryInitLiteralBad {
  NSObject* nullableValue = [self nullableMethod];
  NSDictionary* dict = @{@"key" : nullableValue}; // reports here
  return dict;
}

- (NSDictionary*)indirectNullableKeyInNSDictionaryBad {
  NSObject* nullableKey = [self nullableMethod];
  NSString* nullableKeyString = [nullableKey description];
  NSDictionary* dict = [[NSDictionary alloc]
      initWithObjectsAndKeys:nullableKeyString, @"value", nil]; // reports here
  return dict;
}

- (NSArray*)createArrayByAddingNilBad {
  NSArray* array = @[ [NSObject alloc] ];
  return [array arrayByAddingObject:[self nullableMethod]];
}

- (NSDictionary*)setNullableObjectInDictionaryBad {
  NSMutableDictionary* mutableDict = [NSMutableDictionary dictionary];
  [mutableDict setObject:[self nullableMethod] forKey:@"key"]; // reports here
  return mutableDict;
}

- (NSArray*)addNullableObjectInMutableArrayBad {
  NSMutableArray* mutableArray = [[NSMutableArray alloc] init];
  [mutableArray addObject:[self nullableMethod]]; // reports here
  return mutableArray;
}

- (NSArray*)insertNullableObjectInMutableArrayBad {
  NSMutableArray* mutableArray = [[NSMutableArray alloc] init];
  [mutableArray insertObject:[self nullableMethod] atIndex:0]; // reports here
  return mutableArray;
}

@end

@protocol P
- (NSObject* _Nullable)nullableMethod;
@end

NSDictionary* callNullableMethodFromProtocolBad(id<P> pObject) {
  NSObject* nullableObject = [pObject nullableMethod];
  return @{@"key" : nullableObject};
}
