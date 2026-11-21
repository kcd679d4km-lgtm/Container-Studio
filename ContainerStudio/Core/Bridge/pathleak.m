//
//  pathleak.m
//  ContainerStudio
//
//  Adapted from pathleak by Taj C (forcequit), GPL-3.0-or-later.
//

#import <Foundation/Foundation.h>
#include <sys/mount.h>
#if __has_include(<sys/fsgetpath.h>)
#include <sys/fsgetpath.h>
#else
extern ssize_t fsgetpath(void *buf, size_t bufsize, fsid_t *fsid, uint64_t objid);
#endif
#include "pathleak.h"

NSArray<NSString *> * _Nullable pathleak(NSString *path, uint64_t max_inode) {
    return pathleak_with_progress(path, max_inode, nil, nil);
}

NSArray<NSString *> * _Nullable pathleak_with_progress(
    NSString *path,
    uint64_t max_inode,
    BOOL (^ _Nullable isCancelled)(void),
    void (^ _Nullable progress)(uint64_t current, uint64_t total, NSUInteger found)
) {
    if (path.length == 0 || max_inode < 1) return nil;
    NSString *dir = path;
    while (dir.length > 1 && [dir hasSuffix:@"/"]) {
        dir = [dir substringToIndex:dir.length - 1];
    }

    struct statfs sfs;
    if (statfs(dir.fileSystemRepresentation, &sfs) != 0) return nil;
    fsid_t fsid = sfs.f_fsid;

    char prefix[PATH_MAX];
    if (![dir getFileSystemRepresentation:prefix maxLength:sizeof(prefix)]) return nil;
    size_t prefix_length = strlen(prefix);
    if (prefix_length == 1 && prefix[0] == '/') prefix_length = 0;

    NSFileManager *files = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    char buffer[PATH_MAX];

    const uint64_t reportStep = MAX((uint64_t)10000, max_inode / 100);

    for (uint64_t inode = 1; inode <= max_inode; inode++) {
        if (inode % reportStep == 0) {
            if (isCancelled && isCancelled()) {
                return result;
            }
            if (progress) {
                progress(inode, max_inode, result.count);
            }
        }

        ssize_t n = fsgetpath(buffer, sizeof(buffer), &fsid, inode);
        if (n <= 0) continue;

        if (strncmp(buffer, prefix, prefix_length) != 0) continue;
        if (buffer[prefix_length] != '/') continue;
        if (strchr(buffer + prefix_length + 1, '/')) continue;

        NSString *string = [files stringWithFileSystemRepresentation:buffer length:strlen(buffer)];
        if (string) [result addObject:string];
    }

    if (progress) {
        progress(max_inode, max_inode, result.count);
    }

    return result;
}
