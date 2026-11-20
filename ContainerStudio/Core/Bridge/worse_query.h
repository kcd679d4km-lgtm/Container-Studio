//
//  worse_query.h
//  ContainerStudio
//
//  Adapted from worse_query by Taj C (forcequit), GPL-3.0-or-later.
//

#ifndef worse_query_h
#define worse_query_h

#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdbool.h>

NS_ASSUME_NONNULL_BEGIN

int64_t worse_query(NSString *target, NSString *group, bool alt_flags, bool create_dir);
void worse_query_release(int64_t handle);

NS_ASSUME_NONNULL_END

#endif /* worse_query_h */
