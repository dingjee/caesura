// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.
//
// Caesura addition (narrow patch, see PROVENANCE.md): the guarded command.
//
// The upstream adapter reads the now playing information in one process and
// sends a command in another one, so the media session can change between the
// read and the command. The guarded command does both in one process: it reads
// the session, verifies the guard and sends the command right away.
//
// The identity of a session is the application (its bundle identifier, the
// bundle identifier of its parent application and its process identifier) plus
// the identifier of the media item (the unique identifier of the session, or
// the identifier of its content item). A session that reports no identifier
// of the media item is never acted on: the metadata of the media is no proof
// of the identity of an item, so it is not used for that.

#import <Foundation/Foundation.h>

#include <unistd.h>

#import "MediaRemoteAdapter.h"
#import "adapter/env.h"
#import "adapter/get.h"
#import "adapter/globals.h"
#import "adapter/guarded.h"
#import "adapter/keys.h"
#import "adapter/now_playing.h"
#import "private/MediaRemote.h"
#import "utility/helpers.h"

static NSString *const kGuardedFunction = @"adapter_guarded";

/// The parameter of the guarded command. "-" and an empty value mean that the
/// parameter is not set.
static NSString *guardedParam(NSString *name) {
    NSString *value = getEnvFuncParam(kGuardedFunction, 0, name);
    if (value == nil) {
        return nil;
    }
    NSString *trimmed =
        [value stringByTrimmingCharactersInSet:[NSCharacterSet
                                                   whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0 || [trimmed isEqualToString:@"-"]) {
        return nil;
    }
    return trimmed;
}

/// The stable identity of the media item: the unique identifier of the
/// session, otherwise the identifier of the content item.
static NSString *mediaItemIdentifier(NSDictionary *live) {
    id unique = live[kMRAUniqueIdentifier];
    if ([unique isKindOfClass:[NSString class]] && [unique length] > 0) {
        return unique;
    }
    id content = live[kMRAContentItemIdentifier];
    if ([content isKindOfClass:[NSString class]] && [content length] > 0) {
        return content;
    }
    if ([content isKindOfClass:[NSNumber class]]) {
        NSString *text = [content stringValue];
        if ([text length] > 0) {
            return text;
        }
    }
    return nil;
}

/// Is the application one of the applications that keep playing? The list is
/// given as comma separated bundle identifiers; the parent application of the
/// session counts as well.
static BOOL isAllowedBundle(NSString *bundle, NSString *parent,
                            NSString *allowed) {
    if (allowed == nil) {
        return NO;
    }
    for (NSString *entry in [allowed componentsSeparatedByString:@","]) {
        NSString *trimmed =
            [entry stringByTrimmingCharactersInSet:[NSCharacterSet
                                                       whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) {
            continue;
        }
        if (bundle != nil &&
            [trimmed caseInsensitiveCompare:bundle] == NSOrderedSame) {
            return YES;
        }
        if (parent != nil &&
            [trimmed caseInsensitiveCompare:parent] == NSOrderedSame) {
            return YES;
        }
    }
    return NO;
}

/// The reason why the session may not be acted on — nil when it may.
static NSString *guardReason(NSDictionary *live) {
    id bundle = live[kMRABundleIdentifier];
    id parent = live[kMRAParentApplicationBundleIdentifier];
    id process = live[kMRAProcessIdentifier];

    NSString *expectedBundle = guardedParam(@"bundle");
    NSString *expectedParent = guardedParam(@"parent");
    NSString *expectedProcess = guardedParam(@"process");
    NSString *expectedItem = guardedParam(@"item");
    NSString *allowed = guardedParam(@"allowed");

    if (expectedBundle == nil || expectedProcess == nil ||
        [expectedProcess longLongValue] <= 0) {
        return @"the identity of the media application is unknown";
    }

    if (isAllowedBundle([bundle isKindOfClass:[NSString class]] ? bundle : nil,
                         [parent isKindOfClass:[NSString class]] ? parent : nil,
                         allowed)) {
        return @"the application keeps playing during the break";
    }
    if (expectedBundle != nil) {
        if (![bundle isKindOfClass:[NSString class]] ||
            [bundle caseInsensitiveCompare:expectedBundle] != NSOrderedSame) {
            return @"another application reports now playing information";
        }
    }
    // The parent application is always compared: a session that gains a
    // parent application is another session.
    NSString *currentParent =
        [parent isKindOfClass:[NSString class]] && [parent length] > 0 ? parent : nil;
    if (expectedParent == nil) {
        if (currentParent != nil) {
            return @"the parent application of the session changed";
        }
    } else if (currentParent == nil ||
               [currentParent caseInsensitiveCompare:expectedParent] !=
                   NSOrderedSame) {
        return @"the parent application of the session changed";
    }
    if (expectedProcess != nil) {
        if (![process isKindOfClass:[NSNumber class]] ||
            ![[process stringValue] isEqualToString:expectedProcess]) {
            return @"the process of the session changed";
        }
    }
    // The identity of the media item: only the identifier of the item proves
    // it. A session without one is never acted on.
    if (expectedItem == nil) {
        return @"the identity of the media item is unknown";
    }
    NSString *item = mediaItemIdentifier(live);
    if (item == nil || ![item isEqualToString:expectedItem]) {
        return @"another media item plays";
    }
    return nil;
}

/// Reads the state of the session until it shows the expected one. The state
/// of a player follows the command with a small delay, so the first read can
/// still show the old state. Every read has to show the same session: the
/// state of another application is not the proof that the command went
/// through.
static NSNumber *confirmState(BOOL expectedPlaying) {
    NSNumber *last = nil;
    for (int attempt = 0; attempt < 6; attempt++) {
        NSDictionary *live = internal_get(NO);
        if (live == nil) {
            return last;
        }
        id playing = live[kMRAPlaying];
        if (![playing isKindOfClass:[NSNumber class]]) {
            return last;
        }
        last = playing;
        if ([playing boolValue] == expectedPlaying) {
            if (guardReason(live) != nil) {
                // Another session took over: the state is not the proof.
                return nil;
            }
            return last;
        }
        usleep(50000);
    }
    return last;
}

static void printGuardedResult(NSString *action, NSString *result,
                               NSString *reason, NSDictionary *live,
                               NSNumber *playingAfter) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"action"] = action ?: @"";
    out[@"result"] = result ?: @"";
    if (reason != nil) {
        out[@"reason"] = reason;
    }
    if (live != nil) {
        id bundle = live[kMRABundleIdentifier];
        id parent = live[kMRAParentApplicationBundleIdentifier];
        id process = live[kMRAProcessIdentifier];
        id playing = live[kMRAPlaying];
        out[@"bundleIdentifier"] = bundle ?: [NSNull null];
        out[@"parentApplicationBundleIdentifier"] = parent ?: [NSNull null];
        out[@"processIdentifier"] = process ?: [NSNull null];
        out[@"playing"] = playing ?: [NSNull null];
        NSString *item = mediaItemIdentifier(live);
        out[@"mediaItemIdentifier"] = item ?: [NSNull null];
    }
    if (playingAfter != nil) {
        out[@"playingAfter"] = playingAfter;
    }
    NSString *json = serializeJsonDictionarySafe(out, false);
    if (json == nil) {
        fail(@"Failed to serialize the result of the guarded command");
        return;
    }
    printOut(json);
}

static void runGuarded(NSString *action) {
    if ([action isEqualToString:@"read"]) {
        NSDictionary *live = internal_get(NO);
        if (live == nil) {
            printGuardedResult(action, @"none",
                               @"no application reports now playing information",
                               nil, nil);
            return;
        }
        printGuardedResult(action, @"ok", nil, live, nil);
        return;
    }

    BOOL isPause = [action isEqualToString:@"pause"];
    BOOL isPlay = [action isEqualToString:@"play"];
    if (!isPause && !isPlay) {
        failf(@"Unknown action of the guarded command: %@", action);
        return;
    }

    NSDictionary *live = internal_get(NO);
    if (live == nil) {
        printGuardedResult(action, @"refused",
                           @"no application reports now playing information",
                           nil, nil);
        return;
    }
    NSString *reason = guardReason(live);
    if (reason != nil) {
        printGuardedResult(action, @"refused", reason, live, nil);
        return;
    }
    // The state has to be known: an unknown state is never a paused media.
    id playing = live[kMRAPlaying];
    if (![playing isKindOfClass:[NSNumber class]]) {
        printGuardedResult(action, @"refused", @"the state of the media is unknown",
                           live, nil);
        return;
    }
    BOOL plays = [playing boolValue];
    if (isPause && !plays) {
        printGuardedResult(action, @"refused", @"the media does not play", live,
                           nil);
        return;
    }
    if (isPlay && plays) {
        printGuardedResult(action, @"refused", @"the media plays already", live,
                           nil);
        return;
    }
    // The dry run verifies the guard and reports the decision without
    // sending anything: it is the way to prove the guard on a machine that
    // plays media, without touching the media.
    NSString *dryRun = guardedParam(@"dryrun");
    if ([dryRun isEqualToString:@"1"]) {
        printGuardedResult(action, @"dry-run", nil, live, nil);
        return;
    }
    MRCommand command = isPause ? kMRPause : kMRPlay;
    if (!g_mediaRemote.sendCommand(command, nil)) {
        printGuardedResult(action, @"refused",
                           @"the system refused the command", live, nil);
        return;
    }
    waitForCommandCompletion();
    NSNumber *playingAfter = confirmState(!isPause);
    printGuardedResult(action, @"sent", nil, live, playingAfter);
}

void adapter_guarded_env(void) {
    // The guarded command needs no artwork and it accepts a session without a
    // title: the identity of the session comes from the bundle identifiers and
    // the identifier of the media item, never from the title alone.
    setenv("MEDIAREMOTEADAPTER_OPTION_no_artwork", "", 1);
    setenv("MEDIAREMOTEADAPTER_OPTION_allow_missing_title", "", 1);
    NSString *action = guardedParam(@"action");
    if (action == nil) {
        fail(@"Missing action for the guarded command");
        return;
    }
    runGuarded(action);
}

void adapter_guarded_read(void) { adapter_guarded_env(); }
