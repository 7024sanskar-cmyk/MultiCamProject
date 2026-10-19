#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (BOOL)tryExecute:(void(^)(void))tryBlock error:(NSError * _Nullable * _Nullable)error {
    @try {
        tryBlock();
        return YES;
    }
    @catch (NSException *exception) {
        if (error) {
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @"Unknown reason"]
            };
            *error = [NSError errorWithDomain:@"com.local.multicam.exception" code:-1 userInfo:userInfo];
        }
        return NO;
    }
}

@end