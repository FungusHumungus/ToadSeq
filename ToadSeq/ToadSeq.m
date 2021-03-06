/*
 
 The MIT License (MIT)
 
 Copyright (c) 2013 Stephen Wakely
 
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 
 The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.
 
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 THE SOFTWARE.
 
 */

#import "ToadSeq.h"

@interface ToadSeq()

@property (strong) id cachedNext;
@property (assign) BOOL nextValueCached;

@property (strong) NSMutableArray *transforms;

-(NSArray *) toArrayFromGenerator: (Generator)gen;
-(void) forEach:(Action)action fromGenerator: (Generator)gen;

@end


@implementation ToadSeq


+(ToadSeq *)withGenerator: (Generator) generator {
    return [[ToadSeq alloc] initWithGenerator: generator];
}


-(id)initWithGenerator: (Generator) generator {
    if ( self = [super init]) {
        self.generator = generator;
        self.transforms = [[NSMutableArray alloc] init];
    }
    
    return self;
}

-(BOOL) hasMore {
    BOOL end = NO;

    self.cachedNext = self.generator(&end);
    self.nextValueCached = !end;

    return !end;
}

-(id) getNext {
    BOOL end = NO;

    if (self.nextValueCached) {
        self.nextValueCached = NO;
        return self.cachedNext;
    }

    id next = self.generator(&end);
    return end ? nil : next;
}

-(NSArray *) toArrayFromGenerator: (Generator)gen {
    NSMutableArray *arr = [[NSMutableArray alloc] init];
    
    [self forEach:^(id value)  {
        [arr addObject: value];
    } fromGenerator: gen];
    
    return arr;
}

-(NSArray *) toArray {
    NSMutableArray *arr = [[NSMutableArray alloc] init];
    
    [self forEach:^(id value) {
        [arr addObject: value];
    }];
    
    return arr;
}


-(void) forEach:(Action)action fromGenerator: (Generator)gen {
    BOOL end = NO;
    
    id next = gen(&end);
    while (!end) {
        action(next);
        next = gen(&end);
    }
}

-(void) forEach: (Action) action {
    [self forEach:action fromGenerator: self.generator];
}


-(ToadSeq *)map: (SimpleTransform) transform {
    // Capture the last generator in the sequence.
    Generator gen = self.generator;

    self.generator = ^id (BOOL *end) {
        id value = gen(end);
        return *end? nil : transform(value);
    };

    // Return self so we can chain
    return self;
}

-(ToadSeq *)foldl: (Fold) transform startingWith: (id) start {
    // Capture the last generator in the sequence
    Generator gen = self.generator;
    __block BOOL accumulated = NO;
    
    self.generator = ^id (BOOL *end) {
        if (accumulated || *end) {
            // We've already done the accumulation.
            *end = YES;
            return nil;
        }
        
        id accum = start;
        BOOL e = NO;
        while (!e) {
            id value = gen(&e);
            if (!e)
                accum = transform(accum, value);
        }
        
        accumulated = YES;
        return accum;
    };
    
    return self;
}

-(ToadSeq *)foldl:(Fold)transform {
    // Capture the last generator in the sequence
    Generator gen = self.generator;
    __block BOOL accumulated = NO;
    
    self.generator = ^id (BOOL *end) {
        if (accumulated || *end) {
            // We've already done the accumulation.
            *end = YES;
            return nil;
        }
        
        BOOL e = NO;
        // Get the first element to start with.
        id accum = gen(&e);
        while (!e) {
            id value = gen(&e);
            if (!e)
                accum = transform(accum, value);
        }
        
        accumulated = YES;
        return accum;
    };
    
    
    return self;
}

-(ToadSeq *)filter: (Predicate) predicate {
    // Capture the last generator in the sequence
    Generator gen = self.generator;

    self.generator = ^id (BOOL *end) {
        id value = gen(end);
        // Loop until we get to the end or satisfy the predicate.
        while (!*end && !predicate(value)) {
            value = gen(end);
        }
        
        return *end ? nil : value;
    };
    
    return self;
}

-(ToadSeq *)take: (int)howMany {
    NSAssert(howMany >= 0, @"take called with negative amount");
    
    // Capture the last generator in the sequence
    Generator gen = self.generator;
    __block int taken = 0;
    
    self.generator = ^id (BOOL *end) {
        id value = gen(end);
        
        if (taken >= howMany) {
            *end = YES;
            return nil;
        }

        taken++;
        return value;
    };

    return self;
}


-(ToadSeq *)skip: (int)howMany {
    NSAssert(howMany >= 0, @"skip called with negative amount");
    
    // Capture the last generator in the sequence
    Generator gen = self.generator;
    __block int skipped = 0;
    
    self.generator = ^id (BOOL *end) {
        while (skipped < howMany) {
            gen(end);
            skipped++;
        }

        return gen(end);
    };
    
    return self;
}

-(ToadSeq *)takeWhile: (Predicate) predicate {
    // Capture the last generator in the sequence
    Generator gen = self.generator;
    __block BOOL keepTaking = YES;

    self.generator = ^id (BOOL *end) {
        if (!keepTaking) {
            *end = YES;
            return nil;
        }

        id value = gen(end);

        if (!predicate(value)) {
            *end = YES;
            keepTaking = NO;
            return nil;
        }

        return value;
    };

    return self;
}

-(ToadSeq *)concatWith: (ToadSeq *)seq {
    // Capture the last generator in the sequence
    Generator gen = self.generator;

    self.generator = ^id (BOOL *end) {
        id value = gen(end);
        if (*end) {
            *end = NO;
            value = seq.generator(end);
        }
        
        return value;
    };

    return self;
}

-(ToadSeq *)reverse {
    // Capture the last generator in the sequence
    Generator gen = self.generator;
    __block NSArray *store = nil;
    __block int index;

    // Need to create a weak reference to myself to save a retain cycle
    //__weak TODO : Earlier IOS versions don't like weak.
    ToadSeq *weakMe = self;

    self.generator = ^id (BOOL *end) {
        if (store == nil) {
            // Chuck the data from the pipeline so far into an array
            store = [weakMe toArrayFromGenerator: gen];
            index = store.count - 1;
        }

        if (index < 0) {
            *end = YES;
            return nil;
        }
        
        return store[index--];
    };
    
    return self;
}

@end
