//
//  pathleak.h
//  ContainerStudio
//
//  Adapted from pathleak by Taj C (forcequit), GPL-3.0-or-later.
//

#ifndef pathleak_h
#define pathleak_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSArray<NSString *> * _Nullable pathleak(NSString *filter, uint64_t max_inode);

NSArray<NSString *> * _Nullable pathleak_with_progress(
    NSString *filter,
    uint64_t max_inode,
    BOOL (^ _Nullable isCancelled)(void),
    void (^ _Nullable progress)(uint64_t current, uint64_t total, NSUInteger found)
);

NS_ASSUME_NONNULL_END

#endif /* pathleak_h */
