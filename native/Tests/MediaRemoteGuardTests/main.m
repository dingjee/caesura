#import <Foundation/Foundation.h>
#import "private/MediaRemote.h"
#import "adapter/guarded.h"
#import "adapter/keys.h"

// Link the actual guarded helper against a fake system transport. No private
// framework is loaded, and no process or real media command is created.
MediaRemote *g_mediaRemote;
dispatch_queue_t g_serialdispatchQueue;
static NSMutableDictionary *parameters;
static NSArray<NSDictionary *> *snapshots;
static NSUInteger reads;
static int commands;
static MRCommand lastCommand;
static NSDictionary *answer;
static bool fakeSend(MRCommand command, id options) { commands++; lastCommand=command; return true; }
@interface FakeRemote : NSObject
@end
@implementation FakeRemote
- (MRMediaRemoteSendCommand_t)sendCommand { return fakeSend; }
@end
NSString *getEnvFuncParam(NSString *function, int position, NSString *name) { return parameters[name]; }
NSDictionary *internal_get(BOOL testing) {
    if (!snapshots.count) return nil;
    return snapshots[MIN(reads++, snapshots.count-1)];
}
void waitForCommandCompletion(void) {}
NSString *serializeJsonDictionarySafe(NSDictionary *data, bool pretty) {
    answer=data;
    return @"{}";
}
void printOut(NSString *value) {}
void fail(NSString *value) { fprintf(stderr,"unexpected helper failure\n"); exit(2); }
void failf(NSString *value, ...) { fail(value); }

static NSDictionary *session(BOOL playing) {
    return @{ @"bundleIdentifier": @"com.example.player", @"processIdentifier": @42,
              @"uniqueIdentifier": @"item-1", @"playing": @(playing),
              @"title": @"Private metadata must not be output" };
}
static void prepare(NSString *action, NSArray *states) {
    parameters=[@{ @"action":action, @"bundle":@"com.example.player", @"parent":@"-",
                   @"process":@"42", @"item":@"item-1", @"allowed":@"-", @"dryrun":@"0" } mutableCopy];
    snapshots=states; reads=0; commands=0; answer=nil;
}
static int count=0, failures=0;
static void check(BOOL passed, const char *name) { count++; if (!passed) {failures++; fprintf(stderr,"FAIL %s\n",name);} }
int main(void) { @autoreleasepool {
    g_mediaRemote=(MediaRemote *)[FakeRemote new];
    prepare(@"pause",@[session(YES),session(NO)]); adapter_guarded_env();
    check(commands==1 && lastCommand==kMRPause && [answer[@"playingAfter"] isEqual:@NO],"explicit confirmed pause");
    check(answer[@"title"]==nil && answer[@"artist"]==nil,"metadata omitted");
    prepare(@"play",@[session(NO),session(YES)]); adapter_guarded_env();
    check(commands==1 && lastCommand==kMRPlay && [answer[@"playingAfter"] isEqual:@YES],"explicit confirmed play");
    prepare(@"pause",@[session(YES)]);parameters[@"allowed"]=@"COM.EXAMPLE.PLAYER";adapter_guarded_env();
    check(commands==0 && [answer[@"result"] isEqual:@"refused"],"allowlist bundle");
    NSMutableDictionary *parent=[session(YES) mutableCopy];parent[@"parentApplicationBundleIdentifier"]=@"com.spotify.client";
    prepare(@"pause",@[parent]);parameters[@"parent"]=@"com.spotify.client";parameters[@"allowed"]=@"com.spotify.client";adapter_guarded_env();
    check(commands==0,"allowlist parent");
    prepare(@"pause",@[session(NO)]);adapter_guarded_env();check(commands==0,"already paused");
    prepare(@"play",@[session(YES)]);adapter_guarded_env();check(commands==0,"already playing");
    NSMutableDictionary *unknown=[session(NO) mutableCopy];[unknown removeObjectForKey:@"playing"];
    prepare(@"play",@[unknown]);adapter_guarded_env();check(commands==0,"unknown state");
    NSMutableDictionary *missing=[session(YES) mutableCopy];[missing removeObjectForKey:@"uniqueIdentifier"];
    prepare(@"pause",@[missing]);adapter_guarded_env();check(commands==0,"unknown item");
    prepare(@"pause",@[session(YES)]);parameters[@"item"]=@"other";adapter_guarded_env();check(commands==0,"changed item");
    prepare(@"pause",@[session(YES)]);parameters[@"process"]=@"43";adapter_guarded_env();check(commands==0,"changed process");
    prepare(@"pause",@[parent]);adapter_guarded_env();check(commands==0,"new parent");
    prepare(@"pause",@[session(YES)]);parameters[@"bundle"]=@"-";adapter_guarded_env();check(commands==0,"missing expected app");
    prepare(@"pause",@[session(YES)]);parameters[@"process"]=@"-";adapter_guarded_env();check(commands==0,"missing expected process");
    NSMutableDictionary *emptyParent=[session(YES) mutableCopy];emptyParent[@"parentApplicationBundleIdentifier"]=@"";
    prepare(@"pause",@[emptyParent,session(NO)]);adapter_guarded_env();check(commands==1,"empty parent is absent");
    prepare(@"pause",@[session(YES)]);parameters[@"dryrun"]=@"1";adapter_guarded_env();check(commands==0 && [answer[@"result"] isEqual:@"dry-run"],"dry run cannot send");
    NSMutableDictionary *other=[session(NO) mutableCopy];other[@"uniqueIdentifier"]=@"other";
    prepare(@"pause",@[session(YES),other]);adapter_guarded_env();check(commands==1 && answer[@"playingAfter"]==nil,"confirmation rejects replacement");
    printf("media guard checks=%d failures=%d\n",count,failures);
    return failures ? 1 : 0;
} }
