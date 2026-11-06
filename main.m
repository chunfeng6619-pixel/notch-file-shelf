#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreAudio/CoreAudio.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>
#import <signal.h>

static NSString * const AppID = @"local.wanghao.NotchShelf";
static NSString * const AlcoveID = @"com.henrikruscon.Alcove";
static NSColor *Accent(void) { return [NSColor colorWithSRGBRed:.36 green:.84 blue:.79 alpha:1]; }
static BOOL SafeName(NSString *n) { return n.length && ![n isEqual:@"."] && ![n isEqual:@".."] && [n.lastPathComponent isEqual:n] && [n rangeOfString:@"/"].location == NSNotFound; }
static NSError *ShelfError(NSString *s) { return [NSError errorWithDomain:AppID code:1 userInfo:@{NSLocalizedDescriptionKey:s}]; }
static BOOL UUName(NSString *name) { return [name hasPrefix:@".uuremote_"] && !name.pathExtension.length; }
static BOOL UUMarker(NSURL *url) {
    NSNumber *bytes=nil,*directory=nil;
    return UUName(url.lastPathComponent) && [url getResourceValue:&bytes forKey:NSURLFileSizeKey error:nil] && [url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil] && !directory.boolValue && bytes.unsignedLongLongValue==0;
}
// UU publishes a zero-byte clipboard token, not a file promise. Its local client
// replaces the copied token with real files asynchronously, then removes the token.
// Keep the receiving directory stable until that commit and a quiet metadata window.
static NSArray<NSURL *> *ReceiveUUFiles(NSArray<NSURL *> *markers, NSURL *root, NSTimeInterval timeout, BOOL (^cancelled)(void), NSURL **receivingDirectory, NSError **error) {
    NSFileManager *fm=NSFileManager.defaultManager; NSError *err=nil;
    if(cancelled && cancelled()){if(error)*error=ShelfError(@"已取消UU接收");return nil;}
    NSURL *dir=[root URLByAppendingPathComponent:[@".uu-receive-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    if (![fm createDirectoryAtURL:dir withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:&err]) { if(error)*error=err; return nil; }
    if (receivingDirectory) *receivingDirectory=dir;
    for (NSURL *src in markers) {
        if (!UUMarker(src)) { if(error)*error=ShelfError(@"UU的复制凭据已失效，请从远程电脑重新复制"); return nil; }
        BOOL scoped=[src startAccessingSecurityScopedResource];
        BOOL copied=[fm copyItemAtURL:src toURL:[dir URLByAppendingPathComponent:src.lastPathComponent] error:&err];
        if(scoped)[src stopAccessingSecurityScopedResource];
        if(!copied) { if(error)*error=err; return nil; }
    }
    NSTimeInterval deadline=NSDate.timeIntervalSinceReferenceDate+timeout;
    NSArray *previous=nil; NSUInteger quiet=0;
    while (NSDate.timeIntervalSinceReferenceDate<deadline) {
        @autoreleasepool {
            if(cancelled && cancelled()) { if(error)*error=ShelfError(@"已停止接收UU文件，尚未完成的内容保留在接收目录"); return nil; }
            NSArray *entries=[fm contentsOfDirectoryAtURL:dir includingPropertiesForKeys:@[NSURLFileSizeKey,NSURLContentModificationDateKey,NSURLIsSymbolicLinkKey] options:0 error:&err];
            if(!entries) { if(error)*error=err; return nil; }
            NSMutableArray *real=[NSMutableArray new],*snapshot=[NSMutableArray new]; BOOL pending=NO;
            for (NSURL *u in entries) {
                NSString *name=u.lastPathComponent;
                if(UUName(name)) { pending=YES; continue; }
                if([name isEqual:@".DS_Store"] || [name hasPrefix:@"._"]) continue;
                NSNumber *bytes=nil,*link=nil; NSDate *modified=nil;
                [u getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];
                if(link.boolValue) { if(error)*error=ShelfError(@"UU接收结果包含符号链接，已保留在接收目录供检查"); return nil; }
                [u getResourceValue:&bytes forKey:NSURLFileSizeKey error:nil];[u getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
                [real addObject:u];[snapshot addObject:@[name,bytes ?: @0,modified ?: NSDate.distantPast]];
            }
            [snapshot sortUsingComparator:^NSComparisonResult(NSArray *a,NSArray *b){return [a[0] compare:b[0]];}];
            if(!pending && real.count) {
                quiet=[snapshot isEqual:previous] ? quiet+1 : 0; previous=snapshot.copy;
                if(quiet>=2) return real;
            } else { quiet=0;previous=nil; }
        }
        [NSThread sleepForTimeInterval:.5];
    }
    if(error)*error=ShelfError(@"UU在3分钟内尚未完成传输，占位文件未加入托管台。接收目录已保留，可重新复制后再试");
    return nil;
}
static NSArray<NSURL *> *FileURLs(NSPasteboard *pb) {
    NSMutableArray<NSURL *> *urls=[NSMutableArray new]; NSMutableSet<NSString *> *seen=[NSMutableSet new];
    void (^add)(NSURL *)=^(NSURL *u){
        if (!u.isFileURL) return;
        // File-reference and path URLs can represent the same Finder selection.
        NSURL *pathURL=u.filePathURL ?: u; NSString *key=pathURL.path.stringByStandardizingPath;
        if (!key.length || [seen containsObject:key]) return; [seen addObject:key]; [urls addObject:pathURL];
    };
    for (NSURL *u in [pb readObjectsForClasses:@[[NSURL class]] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}]) add(u);
    // Some file managers still publish the legacy filename-list representation.
    id paths=[pb propertyListForType:@"NSFilenamesPboardType"];
    if ([paths isKindOfClass:NSArray.class]) for (id path in paths) if ([path isKindOfClass:NSString.class] && [path isAbsolutePath]) add([NSURL fileURLWithPath:path]);
    for (NSPasteboardItem *item in pb.pasteboardItems) {
        for (NSString *type in @[NSPasteboardTypeFileURL,@"public.url"]) {
            NSString *value=[item stringForType:type]; NSURL *u=value.length ? [NSURL URLWithString:value] : nil;
            add(u);
        }
    }
    return urls;
}
static NSArray<NSDictionary *> *ClipboardPayloads(NSPasteboard *pb) {
    NSMutableArray *out=[NSMutableArray new];
    // A promised file's preview icon is not the file itself.
    for (NSString *type in pb.types) if ([type containsString:@"promised-file"] || [type isEqual:@"NSFilesPromisePboardType"]) return out;
    NSArray *formats=@[@[NSPasteboardTypePDF,@"pdf"],@[NSPasteboardTypePNG,@"png"],@[@"public.jpeg",@"jpg"],@[@"public.heic",@"heic"],@[NSPasteboardTypeTIFF,@"tiff"],@[NSPasteboardTypeRTF,@"rtf"]];
    NSDateFormatter *fmt=[NSDateFormatter new]; fmt.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; fmt.dateFormat=@"yyyyMMdd-HHmmss";
    NSString *stamp=[fmt stringFromDate:NSDate.date];
    for (NSPasteboardItem *item in pb.pasteboardItems) {
        for (NSArray *format in formats) {
            NSData *data=[item dataForType:format[0]]; if (!data.length) continue;
            NSString *name=[NSString stringWithFormat:@"剪贴板-%@-%lu.%@",stamp,out.count+1,format[1]];
            [out addObject:@{@"name":name,@"data":data}]; break;
        }
    }
    if (!out.count) {
        NSString *text=[pb stringForType:NSPasteboardTypeString];
        if (text.length) [out addObject:@{@"name":[NSString stringWithFormat:@"剪贴板-%@.txt",stamp],@"data":[text dataUsingEncoding:NSUTF8StringEncoding]}];
    }
    return out;
}
static void Text(NSString *s, NSRect r, CGFloat size, NSColor *color, BOOL bold) {
    NSMutableParagraphStyle *p = [NSMutableParagraphStyle new]; p.lineBreakMode = NSLineBreakByTruncatingTail; p.alignment = NSTextAlignmentCenter;
    [s drawInRect:r withAttributes:@{NSFontAttributeName:bold ? [NSFont systemFontOfSize:size weight:NSFontWeightSemibold] : [NSFont systemFontOfSize:size], NSForegroundColorAttributeName:color, NSParagraphStyleAttributeName:p}];
}

@interface ShelfStore : NSObject
@property NSURL *root;
@property NSMutableArray<NSDictionary *> *items;
- (instancetype)initWithRoot:(NSURL *)root error:(NSError **)error;
- (NSURL *)urlForItem:(NSDictionary *)item;
- (NSArray *)importURLs:(NSArray<NSURL *> *)urls errors:(NSMutableArray<NSString *> *)errors;
- (NSArray *)importPayloads:(NSArray<NSDictionary *> *)payloads errors:(NSMutableArray<NSString *> *)errors;
- (NSArray *)adoptUUFiles:(NSArray<NSURL *> *)urls fromDirectory:(NSURL *)directory errors:(NSMutableArray<NSString *> *)errors;
- (BOOL)save:(NSError **)error;
- (BOOL)removeIDs:(NSSet<NSString *> *)ids error:(NSError **)error;
@end

@implementation ShelfStore
- (NSURL *)itemsURL { return [self.root URLByAppendingPathComponent:@"Items" isDirectory:YES]; }
- (instancetype)initWithRoot:(NSURL *)root error:(NSError **)error {
    if (!(self=[super init])) return nil;
    self.root=root; self.items=[NSMutableArray new];
    if (![NSFileManager.defaultManager createDirectoryAtURL:self.itemsURL withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return nil;
    NSNumber *isLink=nil; [self.itemsURL getResourceValue:&isLink forKey:NSURLIsSymbolicLinkKey error:nil];
    if (isLink.boolValue) { if (error) *error=ShelfError(@"托管文件夹已被改为符号链接，请恢复原文件夹"); return nil; }
    NSData *data=[NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"index.json"]];
    if (data) {
        NSDictionary *obj=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([obj isKindOfClass:NSDictionary.class] && [obj[@"items"] isKindOfClass:NSArray.class])
            for (NSDictionary *item in obj[@"items"]) if ([item isKindOfClass:NSDictionary.class] && [self urlForItem:item] && !UUMarker([self urlForItem:item])) [self.items addObject:item];
    }
    // Completed copies whose index commit was interrupted are recovered, never erased.
    NSArray *dirs=[NSFileManager.defaultManager contentsOfDirectoryAtURL:self.itemsURL includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSMutableSet *known=[NSMutableSet new]; for (NSDictionary *x in self.items) [known addObject:x[@"id"]];
    for (NSURL *dir in dirs) {
        NSString *uid=dir.lastPathComponent;
        if (![[NSUUID alloc] initWithUUIDString:uid] || [known containsObject:uid]) continue;
        NSArray *children=[NSFileManager.defaultManager contentsOfDirectoryAtURL:dir includingPropertiesForKeys:nil options:0 error:nil];
        BOOL receiving=NO; for(NSURL *child in children) if(UUName(child.lastPathComponent)) receiving=YES;
        if(receiving) continue;
        NSMutableArray *actual=[NSMutableArray new];for(NSURL *child in children) if(![child.lastPathComponent isEqual:@".DS_Store"] && ![child.lastPathComponent hasPrefix:@"._"]) [actual addObject:child];children=actual;
        if (children.count!=1) continue;
        NSDictionary *item=@{@"id":uid,@"name":[children[0] lastPathComponent],@"added":@([NSDate date].timeIntervalSince1970)};
        if ([self urlForItem:item]) [self.items addObject:item];
    }
    // Resume only completed UU receipts after an interrupted app session.
    for(NSURL *dir in [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.root includingPropertiesForKeys:nil options:0 error:nil]) {
        if(![dir.lastPathComponent hasPrefix:@".uu-receive-"])continue;
        NSArray *entries=[NSFileManager.defaultManager contentsOfDirectoryAtURL:dir includingPropertiesForKeys:nil options:0 error:nil];BOOL pending=NO;NSMutableArray *actual=[NSMutableArray new];
        for(NSURL *child in entries){NSString *name=child.lastPathComponent;if(UUName(name))pending=YES;else if(![name isEqual:@".DS_Store"] && ![name hasPrefix:@"._"]) [actual addObject:child];}
        if(!pending && actual.count) [self adoptUUFiles:actual fromDirectory:dir errors:[NSMutableArray new]];
    }
    return self;
}
- (NSURL *)urlForItem:(NSDictionary *)item {
    NSString *uid=item[@"id"], *name=item[@"name"];
    if (![uid isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:uid] || ![name isKindOfClass:NSString.class] || !SafeName(name)) return nil;
    NSURL *dir=[self.itemsURL URLByAppendingPathComponent:uid isDirectory:YES];
    NSURL *url=[dir URLByAppendingPathComponent:name]; NSNumber *link=nil;
    if (![url getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil] || link.boolValue) return nil;
    // A user-modified parent must not redirect the vault outside its own tree.
    NSString *expected=[self.itemsURL.URLByResolvingSymlinksInPath.path stringByAppendingString:@"/"];
    if (![url.URLByResolvingSymlinksInPath.path hasPrefix:expected]) return nil;
    return url;
}
- (BOOL)save:(NSError **)error {
    NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"items":self.items} options:NSJSONWritingPrettyPrinted error:error];
    return data && [data writeToURL:[self.root URLByAppendingPathComponent:@"index.json"] options:NSDataWritingAtomic error:error];
}
- (NSArray *)importURLs:(NSArray<NSURL *> *)urls errors:(NSMutableArray<NSString *> *)errors {
    NSMutableArray *added=[NSMutableArray new];
    for (NSURL *src in urls) {
        if (!src.isFileURL || !SafeName(src.lastPathComponent)) { [errors addObject:@"请选择实际文件或文件夹"]; continue; }
        if (UUMarker(src)) { [errors addObject:@"UU占位文件必须先完成接收，不能作为普通文件加入"]; continue; }
        NSNumber *link=nil; NSError *err=nil;
        if (![src getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:&err] || link.boolValue) { [errors addObject:err.localizedDescription ?: @"暂不托管符号链接，请选择实际文件"]; continue; }
        NSString *sourcePath=src.URLByResolvingSymlinksInPath.path;
        if ([self.root.URLByResolvingSymlinksInPath.path isEqual:sourcePath] || [self.root.URLByResolvingSymlinksInPath.path hasPrefix:[sourcePath stringByAppendingString:@"/"]]) { [errors addObject:@"不能拖入托管文件仓自身或包含它的上级文件夹"]; continue; }
        NSString *uid=NSUUID.UUID.UUIDString;
        NSURL *staging=[self.root URLByAppendingPathComponent:[@".incoming-" stringByAppendingString:uid] isDirectory:YES];
        NSURL *target=[self.itemsURL URLByAppendingPathComponent:uid isDirectory:YES];
        if (![NSFileManager.defaultManager createDirectoryAtURL:staging withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:&err]) { [errors addObject:err.localizedDescription]; continue; }
        BOOL scope=[src startAccessingSecurityScopedResource];
        BOOL copied=[NSFileManager.defaultManager copyItemAtURL:src toURL:[staging URLByAppendingPathComponent:src.lastPathComponent] error:&err];
        if (scope) [src stopAccessingSecurityScopedResource];
        if (!copied || ![NSFileManager.defaultManager moveItemAtURL:staging toURL:target error:&err]) {
            // A failed partial copy is not indexed. Preserve it in the vault for manual recovery.
            [errors addObject:err.localizedDescription ?: @"保存未完成，请检查可用空间"]; continue;
        }
        NSDictionary *item=@{@"id":uid,@"name":src.lastPathComponent,@"added":@([NSDate date].timeIntervalSince1970)};
        [self.items addObject:item];
        if (![self save:&err]) { [errors addObject:@"副本已保存，但索引写入失败；重新打开时会恢复"]; }
        [added addObject:item];
    }
    return added;
}
- (BOOL)removeIDs:(NSSet<NSString *> *)ids error:(NSError **)error {
    BOOL ok=YES; NSMutableArray *remaining=[NSMutableArray new];
    for (NSDictionary *item in self.items) {
        if (![ids containsObject:item[@"id"]]) { [remaining addObject:item]; continue; }
        NSURL *url=[self urlForItem:item];
        if (!url || ![NSFileManager.defaultManager trashItemAtURL:url resultingItemURL:nil error:error]) { [remaining addObject:item]; ok=NO; continue; }
        // Remove only the empty UUID wrapper. File content is in the normal recoverable Trash.
        NSURL *wrapper=url.URLByDeletingLastPathComponent;
        NSArray *left=[NSFileManager.defaultManager contentsOfDirectoryAtURL:wrapper includingPropertiesForKeys:nil options:0 error:nil];
        if(left && !left.count) [NSFileManager.defaultManager removeItemAtURL:wrapper error:nil];
    }
    self.items=remaining;
    return [self save:error] && ok;
}
- (NSArray *)importPayloads:(NSArray<NSDictionary *> *)payloads errors:(NSMutableArray<NSString *> *)errors {
    NSMutableArray *added=[NSMutableArray new];
    for (NSDictionary *payload in payloads) {
        NSString *name=payload[@"name"]; NSData *data=payload[@"data"];
        if (![name isKindOfClass:NSString.class] || !SafeName(name) || ![data isKindOfClass:NSData.class] || !data.length) { [errors addObject:@"剪贴板内容未能读取，请重新复制"]; continue; }
        NSString *uid=NSUUID.UUID.UUIDString; NSError *err=nil;
        NSURL *staging=[self.root URLByAppendingPathComponent:[@".incoming-" stringByAppendingString:uid] isDirectory:YES];
        NSURL *target=[self.itemsURL URLByAppendingPathComponent:uid isDirectory:YES];
        if (![NSFileManager.defaultManager createDirectoryAtURL:staging withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:&err] || ![data writeToURL:[staging URLByAppendingPathComponent:name] options:NSDataWritingAtomic error:&err] || ![NSFileManager.defaultManager moveItemAtURL:staging toURL:target error:&err]) { [errors addObject:err.localizedDescription ?: @"剪贴板内容未能保存"]; continue; }
        NSDictionary *item=@{@"id":uid,@"name":name,@"added":@([NSDate date].timeIntervalSince1970)}; [self.items addObject:item];
        if (![self save:&err]) [errors addObject:@"内容已保存，但索引写入失败；重新打开时会恢复"];
        [added addObject:item];
    }
    return added;
}
- (NSArray *)adoptUUFiles:(NSArray<NSURL *> *)urls fromDirectory:(NSURL *)directory errors:(NSMutableArray<NSString *> *)errors {
    NSString *prefix=@".uu-receive-";
    BOOL owned=[directory.URLByResolvingSymlinksInPath.URLByDeletingLastPathComponent.path isEqual:self.root.URLByResolvingSymlinksInPath.path] && [directory.lastPathComponent hasPrefix:prefix] && [[NSUUID alloc] initWithUUIDString:[directory.lastPathComponent substringFromIndex:prefix.length]];
    if(!owned){[errors addObject:@"UU接收目录校验失败"];return @[];}
    NSMutableArray *added=[NSMutableArray new];NSFileManager *fm=NSFileManager.defaultManager;
    for(NSURL *src in urls){
        NSNumber *link=nil;[src getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];
        if(![src.URLByDeletingLastPathComponent.path isEqual:directory.path] || !SafeName(src.lastPathComponent) || UUName(src.lastPathComponent) || link.boolValue){[errors addObject:@"UU接收文件路径校验失败"];continue;}
        NSString *uid=NSUUID.UUID.UUIDString;NSURL *wrapper=[self.itemsURL URLByAppendingPathComponent:uid isDirectory:YES];NSError *err=nil;
        if(![fm createDirectoryAtURL:wrapper withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:&err] || ![fm moveItemAtURL:src toURL:[wrapper URLByAppendingPathComponent:src.lastPathComponent] error:&err]){[errors addObject:err.localizedDescription ?: @"UU文件入库未完成"];continue;}
        NSDictionary *item=@{@"id":uid,@"name":src.lastPathComponent,@"added":@([NSDate date].timeIntervalSince1970)};[self.items addObject:item];if(![self save:&err])[errors addObject:@"文件已收到，但索引未写入，重新打开时会恢复"];[added addObject:item];
    }
    NSArray *left=[fm contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil options:0 error:nil];if(left && !left.count)[fm removeItemAtURL:directory error:nil];
    return added;
}
@end

@class ShelfApp, ShelfGrid;
@interface ShelfPanel : NSPanel @end
@implementation ShelfPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface ShelfApp : NSObject <NSApplicationDelegate, NSSharingServiceDelegate>
@property ShelfStore *store;
@property ShelfPanel *panel;
@property NSPanel *badgePanel;
@property NSPanel *catcherPanel;
@property NSButton *statusButton;
@property NSString *lastError;
@property ShelfGrid *grid;
@property NSTextField *titleLabel;
@property NSTextField *subtitleLabel;
@property NSButton *badgeButton;
@property NSProgressIndicator *spinner;
@property id globalMonitor;
@property id localMonitor;
@property NSTimer *coexistTimer;
@property NSTimer *dragTimer;
@property BOOL copying, draggingOut, dragSession, panelPinned, airDropActive;
@property NSSharingService *airDropService;
@property NSTimer *airDropWatchTimer;
@property BOOL airDropWindowSeen;
@property NSTimeInterval airDropStartedAt;
@property BOOL uuReceiving;
@property (atomic) BOOL importCancelled;
@property NSInteger dragStartCount;
@property NSTimeInterval lastDragCheck, quietUntil;
@property NSTimeInterval hudUntil;
@property NSTimeInterval dragDeadline;
@property NSTimeInterval airDropHoldUntil;
@property NSRect previousAlcoveBounds;
@property BOOL alcoveHasBounds;
@property NSInteger alcoveWindowLevel;
@property AudioDeviceID audioDevice;
@property int lockFD;
@property dispatch_source_t terminationSignal;
- (void)showShelf:(BOOL)activate;
- (void)hideShelf;
- (void)importFiles:(NSArray<NSURL *> *)urls;
- (void)importFiles:(NSArray<NSURL *> *)urls payloads:(NSArray<NSDictionary *> *)payloads;
- (void)pasteFiles;
- (void)updateUI;
- (void)refreshGeometry;
- (NSRect)notchRect;
- (void)startVolumeObserver;
- (void)probeDraggedFiles;
- (void)message:(NSString *)s;
- (void)scheduleHide;
- (void)airDrop:(id)sender;
- (void)finishAirDropSession;
- (void)airDropAppDidBecomeActive:(NSNotification *)notification;
- (void)checkAirDropWindow:(NSTimer *)timer;
@end

static OSStatus AudioChanged(AudioObjectID object, UInt32 count, const AudioObjectPropertyAddress addresses[], void *context) {
    ShelfApp *app=(__bridge ShelfApp *)context;
    dispatch_async(dispatch_get_main_queue(),^{
        if (object==kAudioObjectSystemObject) [app startVolumeObserver];
        else { app.hudUntil=NSDate.timeIntervalSinceReferenceDate+3; [app refreshGeometry]; }
    }); return noErr;
}

@interface ShelfAXItem : NSAccessibilityElement
@property (weak) ShelfGrid *grid;
@property NSUInteger index;
@end

@interface ShelfGrid : NSView <NSDraggingSource>
@property (weak) ShelfApp *app;
@property NSMutableIndexSet *selection;
@property NSMutableDictionary<NSString *,NSImage *> *icons;
@property NSRect marquee;
@property BOOL drawingMarquee, dropHover;
- (void)reload;
- (NSArray<NSURL *> *)selectedURLs;
@end

@implementation ShelfAXItem
- (BOOL)accessibilityPerformPress { [self.grid.selection removeAllIndexes]; [self.grid.selection addIndex:self.index]; [self.grid setNeedsDisplay:YES]; [self.grid.window makeFirstResponder:self.grid]; return YES; }
- (BOOL)isAccessibilitySelected { return [self.grid.selection containsIndex:self.index]; }
@end

@implementation ShelfGrid
- (instancetype)initWithFrame:(NSRect)r {
    if ((self=[super initWithFrame:r])) { self.selection=[NSMutableIndexSet new]; self.icons=[NSMutableDictionary new]; [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]]; }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return NSAccessibilityListRole; }
- (NSString *)accessibilityLabel { return @"已保存的托管文件，支持框选、复制、粘贴和删除"; }
- (NSRect)rectAt:(NSUInteger)i { return NSMakeRect(12+(i%4)*130, 12+(i/4)*116, 122,108); }
- (NSArray *)accessibilityChildren {
    NSMutableArray *a=[NSMutableArray new];
    for (NSUInteger i=0;i<self.app.store.items.count;i++) {
        NSRect r=[self.window convertRectToScreen:[self convertRect:[self rectAt:i] toView:nil]];
        ShelfAXItem *e=[ShelfAXItem new]; e.accessibilityRole=NSAccessibilityButtonRole; e.accessibilityFrame=r; e.accessibilityLabel=self.app.store.items[i][@"name"]; e.accessibilityParent=self; e.grid=self; e.index=i; [a addObject:e];
    }
    return a;
}
- (NSArray *)accessibilityRows { return self.accessibilityChildren; }
- (NSArray *)accessibilityVisibleChildren { return self.accessibilityChildren; }
- (void)reload {
    [self.selection removeIndexesInRange:NSMakeRange(self.app.store.items.count,NSUIntegerMax-self.app.store.items.count)];
    CGFloat height=MAX(self.enclosingScrollView.contentSize.height,12+ceil(self.app.store.items.count/4.0)*116);
    [self setFrameSize:NSMakeSize(548,height)]; [self.icons removeAllObjects]; [self removeAllToolTips];
    for (NSUInteger i=0;i<self.app.store.items.count;i++) [self addToolTipRect:[self rectAt:i] owner:self userData:(void *)(uintptr_t)(i+1)];
    [self setNeedsDisplay:YES];
    NSAccessibilityPostNotification(self,NSAccessibilityLayoutChangedNotification);
}
- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)data {
    NSUInteger i=(NSUInteger)(uintptr_t)data-1;
    return i<self.app.store.items.count ? [self.app.store.items[i][@"name"] stringByAppendingString:@"\nDelete 仅移除托管副本"] : @"";
}
- (void)drawRect:(NSRect)dirty {
    [[NSColor clearColor] setFill]; NSRectFillUsingOperation(dirty,NSCompositingOperationCopy);
    if (!self.app.store.items.count) {
        NSImage *im=[NSImage imageWithSystemSymbolName:@"tray.and.arrow.down" accessibilityDescription:nil];
        im=[im imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[[NSColor colorWithWhite:.55 alpha:1]]]];
        [im drawInRect:NSMakeRect(NSMidX(self.visibleRect)-24,NSMidY(self.visibleRect)-22,48,44) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:.55];
    }
    for (NSUInteger i=0;i<self.app.store.items.count;i++) {
        NSRect r=[self rectAt:i]; if (!NSIntersectsRect(dirty,r)) continue;
        NSDictionary *item=self.app.store.items[i]; BOOL selected=[self.selection containsIndex:i];
        NSBezierPath *card=[NSBezierPath bezierPathWithRoundedRect:r xRadius:13 yRadius:13];
        [(selected ? [Accent() colorWithAlphaComponent:.16] : [NSColor colorWithWhite:1 alpha:.045]) setFill]; [card fill];
        [(selected ? [Accent() colorWithAlphaComponent:.68] : [NSColor colorWithWhite:1 alpha:.045]) setStroke]; [card setLineWidth:1]; [card stroke];
        NSImage *icon=self.icons[item[@"id"]];
        if (!icon) { NSURL *u=[self.app.store urlForItem:item]; icon=u ? [NSWorkspace.sharedWorkspace iconForFile:u.path] : [NSImage imageWithSystemSymbolName:@"doc" accessibilityDescription:nil]; self.icons[item[@"id"]]=icon; }
        [icon drawInRect:NSMakeRect(r.origin.x+(r.size.width-44)/2,r.origin.y+12,44,44) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
        Text(item[@"name"],NSMakeRect(r.origin.x+6,r.origin.y+65,r.size.width-12,20),11.5,[NSColor whiteColor],NO);
    }
    if (self.drawingMarquee) { [[Accent() colorWithAlphaComponent:.14] setFill]; NSRectFill(self.marquee); [[Accent() colorWithAlphaComponent:.9] setStroke]; [NSBezierPath strokeRect:self.marquee]; }
    if (self.dropHover) { [Accent() setStroke]; NSBezierPath *p=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.visibleRect,3,3) xRadius:14 yRadius:14]; p.lineWidth=2; [p stroke]; }
}
- (NSInteger)indexAt:(NSPoint)p { for (NSUInteger i=0;i<self.app.store.items.count;i++) if (NSPointInRect(p,[self rectAt:i])) return (NSInteger)i; return NSNotFound; }
- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self]; NSPoint start=[self convertPoint:event.locationInWindow fromView:nil]; NSInteger hit=[self indexAt:start];
    BOOL additive=(event.modifierFlags&(NSEventModifierFlagCommand|NSEventModifierFlagShift))!=0;
    NSIndexSet *base=additive ? self.selection.copy : [NSIndexSet indexSet];
    if (hit!=NSNotFound) {
        if (additive) { if ([self.selection containsIndex:hit]) [self.selection removeIndex:hit]; else [self.selection addIndex:hit]; }
        else if (![self.selection containsIndex:hit]) { [self.selection removeAllIndexes]; [self.selection addIndex:hit]; }
        [self setNeedsDisplay:YES];
        if (event.clickCount==2) { NSURL *u=[self.app.store urlForItem:self.app.store.items[hit]]; if (u) [NSWorkspace.sharedWorkspace openURL:u]; return; }
    } else { self.selection=[base mutableCopy]; [self setNeedsDisplay:YES]; }
    while (YES) {
        NSEvent *next=[self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp];
        if (!next || next.type==NSEventTypeLeftMouseUp) break;
        NSPoint point=[self convertPoint:next.locationInWindow fromView:nil];
        if (hypot(point.x-start.x,point.y-start.y)<4) continue;
        if (hit!=NSNotFound && [self.selection containsIndex:hit]) {
            NSMutableArray *drag=[NSMutableArray new];
            for (NSURL *url in self.selectedURLs) {
                NSDraggingItem *item=[[NSDraggingItem alloc] initWithPasteboardWriter:url];
                [item setDraggingFrame:NSMakeRect(start.x-22,start.y-22,44,44) contents:[NSWorkspace.sharedWorkspace iconForFile:url.path]]; [drag addObject:item];
            }
            if (drag.count) { self.app.draggingOut=YES; [self beginDraggingSessionWithItems:drag event:next source:self]; } return;
        }
        self.drawingMarquee=YES; self.marquee=NSMakeRect(MIN(start.x,point.x),MIN(start.y,point.y),fabs(start.x-point.x),fabs(start.y-point.y));
        self.selection=[base mutableCopy];
        for (NSUInteger i=0;i<self.app.store.items.count;i++) if (NSIntersectsRect(self.marquee,[self rectAt:i])) [self.selection addIndex:i];
        [self autoscroll:next]; [self setNeedsDisplay:YES];
    }
    self.drawingMarquee=NO; [self setNeedsDisplay:YES];
}
- (NSArray<NSURL *> *)selectedURLs {
    NSMutableArray *urls=[NSMutableArray new];
    [self.selection enumerateIndexesUsingBlock:^(NSUInteger i,BOOL *stop) { if (i<self.app.store.items.count) { NSURL *u=[self.app.store urlForItem:self.app.store.items[i]]; if (u) [urls addObject:u]; } }]; return urls;
}
- (void)copy:(id)sender { NSArray *urls=self.selectedURLs; if (!urls.count) return; [NSPasteboard.generalPasteboard clearContents]; [NSPasteboard.generalPasteboard writeObjects:urls]; [self.app message:[NSString stringWithFormat:@"已复制 %lu 个文件，可粘贴到访达等位置",urls.count]]; }
- (void)paste:(id)sender { [self.app pasteFiles]; }
- (void)selectAll:(id)sender { [self.selection addIndexesInRange:NSMakeRange(0,self.app.store.items.count)]; [self setNeedsDisplay:YES]; }
- (void)delete:(id)sender {
    if (self.app.copying || !self.selection.count) return;
    NSMutableSet *ids=[NSMutableSet new];
    [self.selection enumerateIndexesUsingBlock:^(NSUInteger i,BOOL *stop) { if (i<self.app.store.items.count) [ids addObject:self.app.store.items[i][@"id"]]; }];
    NSError *e=nil; BOOL ok=[self.app.store removeIDs:ids error:&e]; [self.selection removeAllIndexes]; [self.app updateUI];
    [self.app message:ok ? @"已将托管副本移入废纸篓，原件保留" : e.localizedDescription];
}
- (void)keyDown:(NSEvent *)event {
    if ((event.modifierFlags & NSEventModifierFlagCommand) && [self performKeyEquivalent:event]) return;
    if (event.keyCode==53) { [self.app hideShelf]; return; }
    if (event.keyCode==51 || event.keyCode==117) { [self delete:nil]; return; }
    [super keyDown:event];
}
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (!(event.modifierFlags & NSEventModifierFlagCommand)) return [super performKeyEquivalent:event];
    NSString *key=event.charactersIgnoringModifiers.lowercaseString;
    if ([key isEqual:@"c"]) { [self copy:nil]; return YES; }
    if ([key isEqual:@"v"]) { [self paste:nil]; return YES; }
    if ([key isEqual:@"a"]) { [self selectAll:nil]; return YES; }
    return [super performKeyEquivalent:event];
}
- (NSDragOperation)draggingSession:(NSDraggingSession *)s sourceOperationMaskForDraggingContext:(NSDraggingContext)c { return NSDragOperationCopy; }
- (void)draggingSession:(NSDraggingSession *)s endedAtPoint:(NSPoint)p operation:(NSDragOperation)o { self.app.draggingOut=NO; [self.app scheduleHide]; }
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)s { if (s.draggingSource==self || !FileURLs(s.draggingPasteboard).count) return NSDragOperationNone; self.dropHover=YES; [self setNeedsDisplay:YES]; return NSDragOperationCopy; }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)s { return s.draggingSource==self ? NSDragOperationNone : NSDragOperationCopy; }
- (void)draggingExited:(id<NSDraggingInfo>)s { self.dropHover=NO; [self setNeedsDisplay:YES]; [self.app scheduleHide]; }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)s { return !self.app.copying; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)s { NSArray *urls=FileURLs(s.draggingPasteboard); self.dropHover=NO; [self setNeedsDisplay:YES]; if (!urls.count || s.draggingSource==self) return NO; [self.app importFiles:urls]; return YES; }
@end

@interface ShelfSurface : NSView
@property (weak) ShelfApp *app;
@property NSTrackingArea *tracking;
@property BOOL invisible;
@end
@implementation ShelfSurface
- (instancetype)initWithFrame:(NSRect)r { if ((self=[super initWithFrame:r])) [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]]; return self; }
- (void)drawRect:(NSRect)r {
    if (self.invisible) return;
    CGFloat w=self.bounds.size.width,h=self.bounds.size.height,corner=24;
    // The expanded black silhouette starts at the screen edge, including the notch.
    NSBezierPath *p=[NSBezierPath bezierPath]; [p moveToPoint:NSMakePoint(0,h)]; [p lineToPoint:NSMakePoint(w,h)];
    [p lineToPoint:NSMakePoint(w,corner)]; [p curveToPoint:NSMakePoint(w-corner,0) controlPoint1:NSMakePoint(w,corner*.45) controlPoint2:NSMakePoint(w-corner*.45,0)];
    [p lineToPoint:NSMakePoint(corner,0)]; [p curveToPoint:NSMakePoint(0,corner) controlPoint1:NSMakePoint(corner*.45,0) controlPoint2:NSMakePoint(0,corner*.45)]; [p closePath];
    [NSColor.blackColor setFill]; [p fill];
}
- (void)updateTrackingAreas { if (self.tracking) [self removeTrackingArea:self.tracking]; self.tracking=[[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingMouseEnteredAndExited|NSTrackingActiveAlways|NSTrackingInVisibleRect owner:self userInfo:nil]; [self addTrackingArea:self.tracking]; [super updateTrackingAreas]; }
- (void)mouseExited:(NSEvent *)e { [self.app scheduleHide]; }
- (void)mouseEntered:(NSEvent *)e { if (!self.invisible && !self.app.airDropActive) self.app.panelPinned=NO; }
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)s { if (self.app.draggingOut || !FileURLs(s.draggingPasteboard).count) return NSDragOperationNone; [self.app showShelf:NO]; return NSDragOperationCopy; }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)s { return self.app.draggingOut ? NSDragOperationNone : NSDragOperationCopy; }
- (void)draggingExited:(id<NSDraggingInfo>)s { [self.app scheduleHide]; }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)s { return !self.app.copying; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)s { NSArray *urls=FileURLs(s.draggingPasteboard); if (!urls.count || self.app.draggingOut) return NO; [self.app importFiles:urls]; return YES; }
@end

@implementation ShelfApp
- (NSScreen *)notchedScreen {
    for (NSScreen *s in NSScreen.screens) if (@available(macOS 12.0,*)) { if (s.safeAreaInsets.top>0) return s; }
    return NSScreen.mainScreen ?: NSScreen.screens.firstObject;
}
- (NSRect)notchRect {
    NSScreen *s=self.notchedScreen; CGFloat top=32,width=190;
    if (@available(macOS 12.0,*)) { top=MAX(26,s.safeAreaInsets.top); if (s.safeAreaInsets.top>0) width=s.frame.size.width-s.auxiliaryTopLeftArea.size.width-s.auxiliaryTopRightArea.size.width; }
    return NSMakeRect(NSMidX(s.frame)-width/2,NSMaxY(s.frame)-top,width,top);
}
- (NSRect)alcoveBounds {
    // Public on-screen window rectangles only: no pixels, names, text, audio, or recording permission.
    NSArray *apps=[NSRunningApplication runningApplicationsWithBundleIdentifier:AlcoveID]; NSMutableSet *pids=[NSMutableSet new]; for (NSRunningApplication *a in apps) [pids addObject:@(a.processIdentifier)];
    NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements,kCGNullWindowID));
    CGFloat desktopTop=NSMaxY(NSScreen.screens.firstObject.frame); NSRect result=NSZeroRect; NSRect notch=self.notchRect; self.alcoveWindowLevel=0;
    for (NSDictionary *d in windows) {
        if (![pids containsObject:d[(id)kCGWindowOwnerPID]] || [d[(id)kCGWindowAlpha] doubleValue]<.05) continue;
        CGRect cg; if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)d[(id)kCGWindowBounds],&cg)) continue;
        NSRect r=NSMakeRect(cg.origin.x,desktopTop-cg.origin.y-cg.size.height,cg.size.width,cg.size.height);
        if (r.size.width>700 || r.size.height>420 || r.size.width<30) continue;
        if (fabs(NSMidX(r)-NSMidX(notch))<180 && NSMaxY(r)>NSMinY(notch)-80) { result=NSIsEmptyRect(result) ? r : NSUnionRect(result,r); self.alcoveWindowLevel=MAX(self.alcoveWindowLevel,[d[(id)kCGWindowLayer] integerValue]); }
    }
    return result;
}
- (NSPanel *)smallPanel:(NSRect)r {
    NSPanel *p=[[NSPanel alloc] initWithContentRect:r styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    p.opaque=NO; p.backgroundColor=NSColor.clearColor; p.hasShadow=NO; p.level=NSStatusWindowLevel+3; p.hidesOnDeactivate=NO; p.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary|NSWindowCollectionBehaviorStationary; return p;
}
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    for (NSDictionary *marker in [NSUserDefaults.standardUserDefaults arrayForKey:@"SuppressedAlcoveInstances"]) {
        NSRunningApplication *a=[NSRunningApplication runningApplicationWithProcessIdentifier:[marker[@"pid"] intValue]];
        if ([a.bundleIdentifier isEqual:AlcoveID] && fabs(a.launchDate.timeIntervalSince1970-[marker[@"started"] doubleValue])<1 && a.hidden) [a unhide];
    }
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"SuppressedAlcoveInstances"];
    NSURL *root=[[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:AppID isDirectory:YES];
    NSError *error=nil; self.store=[[ShelfStore alloc] initWithRoot:root error:&error];
    if (!self.store) { NSAlert *a=[NSAlert new]; a.messageText=@"文件托管台暂时无法启动"; a.informativeText=error.localizedDescription ?: @"无法访问本机保存位置"; [a runModal]; [NSApp terminate:nil]; return; }
    self.lockFD=open([[root URLByAppendingPathComponent:@".instance.lock"].path fileSystemRepresentation],O_CREAT|O_RDWR,0600);
    if (self.lockFD<0 || flock(self.lockFD,LOCK_EX|LOCK_NB)!=0) { [NSApp terminate:nil]; return; }
    signal(SIGTERM,SIG_IGN); self.terminationSignal=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGTERM,0,dispatch_get_main_queue());
    dispatch_source_set_event_handler(self.terminationSignal,^{ [NSApp terminate:nil]; }); dispatch_resume(self.terminationSignal);
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.panel=[[ShelfPanel alloc] initWithContentRect:NSMakeRect(0,0,560,288) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    self.panel.opaque=NO; self.panel.backgroundColor=NSColor.clearColor; self.panel.hasShadow=NO; self.panel.level=NSStatusWindowLevel+4; self.panel.hidesOnDeactivate=NO; self.panel.title=@"文件托管台"; self.panel.accessibilityLabel=@"文件托管台";
    self.panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
    ShelfSurface *surface=[[ShelfSurface alloc] initWithFrame:NSMakeRect(0,0,560,288)]; surface.app=self; surface.wantsLayer=YES; surface.layer.masksToBounds=YES; self.panel.contentView=surface;
    self.titleLabel=[NSTextField labelWithString:@"文件托管台"]; self.titleLabel.hidden=YES; self.titleLabel.frame=NSZeroRect; self.titleLabel.font=[NSFont systemFontOfSize:16 weight:NSFontWeightSemibold]; self.titleLabel.textColor=NSColor.whiteColor; [surface addSubview:self.titleLabel];
    self.subtitleLabel=[NSTextField labelWithString:@"拖入即保存 · 多文件 · ⌘C / ⌘V · Delete"]; self.subtitleLabel.hidden=YES; self.subtitleLabel.frame=NSZeroRect; self.subtitleLabel.font=[NSFont systemFontOfSize:10.5]; self.subtitleLabel.textColor=[NSColor colorWithWhite:.56 alpha:1]; [surface addSubview:self.subtitleLabel];
    NSButton *close=[NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark" accessibilityDescription:@"收起托管台"] target:self action:@selector(close:)]; close.frame=NSMakeRect(515,251,26,26); close.toolTip=@"收起"; close.bordered=NO; close.contentTintColor=[NSColor colorWithWhite:.65 alpha:1]; [surface addSubview:close];
    NSButton *folder=[NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"folder" accessibilityDescription:@"在访达中打开托管文件夹"] target:self action:@selector(openFolder:)]; folder.frame=NSMakeRect(20,251,26,26); folder.toolTip=@"在访达中查看文件"; folder.bordered=NO; folder.contentTintColor=[NSColor colorWithWhite:.65 alpha:1]; [surface addSubview:folder];
    NSButton *airDrop=[NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"antenna.radiowaves.left.and.right" accessibilityDescription:@"通过隔空投送发送选中文件"] target:self action:@selector(airDrop:)]; airDrop.frame=NSMakeRect(52,251,26,26); airDrop.toolTip=@"隔空投送选中文件"; airDrop.bordered=NO; airDrop.contentTintColor=[NSColor colorWithWhite:.65 alpha:1]; [surface addSubview:airDrop];
    NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(6,12,548,222)]; scroll.drawsBackground=NO; scroll.hasVerticalScroller=YES; scroll.autohidesScrollers=YES; scroll.borderType=NSNoBorder;
    self.grid=[[ShelfGrid alloc] initWithFrame:NSMakeRect(0,0,548,222)]; self.grid.app=self; scroll.documentView=self.grid; [surface addSubview:scroll];
    NSTextField *foot=[NSTextField labelWithString:@"保存在本机 · 原文件保留"]; foot.font=[NSFont systemFontOfSize:9.5]; foot.textColor=[NSColor colorWithWhite:.38 alpha:1]; foot.hidden=YES; foot.frame=NSZeroRect; [surface addSubview:foot];
    self.spinner=[[NSProgressIndicator alloc] initWithFrame:NSMakeRect(488,256,16,16)]; self.spinner.style=NSProgressIndicatorStyleSpinning; self.spinner.controlSize=NSControlSizeSmall; self.spinner.displayedWhenStopped=NO; [surface addSubview:self.spinner];
    self.statusButton=[NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"exclamationmark.circle" accessibilityDescription:@"查看未完成的文件"] target:self action:@selector(showError:)]; self.statusButton.frame=NSMakeRect(484,251,26,26); self.statusButton.bordered=NO; self.statusButton.contentTintColor=NSColor.systemOrangeColor; self.statusButton.hidden=YES; [surface addSubview:self.statusButton];
    self.badgePanel=[self smallPanel:NSMakeRect(0,0,24,12)]; self.badgeButton=[NSButton buttonWithTitle:@"" target:self action:@selector(toggle:)]; self.badgeButton.frame=NSMakeRect(0,0,24,12); self.badgeButton.bezelStyle=NSBezelStyleInline; self.badgeButton.bordered=NO; self.badgeButton.wantsLayer=YES; self.badgeButton.layer.cornerRadius=6; self.badgeButton.layer.maskedCorners=kCALayerMinXMinYCorner|kCALayerMaxXMinYCorner; self.badgeButton.layer.backgroundColor=NSColor.blackColor.CGColor; self.badgeButton.contentTintColor=Accent(); self.badgeButton.image=[[NSImage imageWithSystemSymbolName:@"tray.full.fill" accessibilityDescription:@"打开文件托管台"] imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:9 weight:NSFontWeightRegular]]; self.badgeButton.imagePosition=NSImageOnly; self.badgeButton.font=[NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightMedium]; self.badgePanel.contentView=self.badgeButton;
    self.catcherPanel=[self smallPanel:self.notchRect]; self.catcherPanel.level=NSStatusWindowLevel+5; ShelfSurface *catcher=[[ShelfSurface alloc] initWithFrame:NSMakeRect(0,0,self.notchRect.size.width,self.notchRect.size.height)]; catcher.app=self; catcher.invisible=YES; self.catcherPanel.contentView=catcher;
    NSMenu *menu=[NSMenu new]; NSMenuItem *appItem=[[NSMenuItem alloc] initWithTitle:@"文件托管台" action:nil keyEquivalent:@""]; [menu addItem:appItem]; NSMenu *appMenu=[NSMenu new]; [appMenu addItemWithTitle:@"退出文件托管台" action:@selector(terminate:) keyEquivalent:@"q"]; appItem.submenu=appMenu;
    NSMenuItem *editItem=[[NSMenuItem alloc] initWithTitle:@"编辑" action:nil keyEquivalent:@""]; [menu addItem:editItem]; NSMenu *edit=[NSMenu new]; for (NSArray *def in @[@[@"复制",@"copy:",@"c"],@[@"粘贴",@"paste:",@"v"],@[@"全选",@"selectAll:",@"a"]]) [edit addItemWithTitle:def[0] action:NSSelectorFromString(def[1]) keyEquivalent:def[2]]; editItem.submenu=edit; [NSApp setMainMenu:menu];
    __weak ShelfApp *weak=self;
    NSEventMask mask=NSEventMaskLeftMouseDown|NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp;
    self.globalMonitor=[NSEvent addGlobalMonitorForEventsMatchingMask:mask handler:^(NSEvent *e){ [weak handleMouse:e own:NO]; }];
    self.localMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent *(NSEvent *e){ [weak handleMouse:e own:YES]; return e; }];
    AudioObjectPropertyAddress output={kAudioHardwarePropertyDefaultOutputDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    AudioObjectAddPropertyListener(kAudioObjectSystemObject,&output,AudioChanged,(__bridge void *)self); [self startVolumeObserver];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(woke:) name:NSWorkspaceDidWakeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(screenChanged:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(airDropAppDidBecomeActive:) name:NSApplicationDidBecomeActiveNotification object:NSApp];
    [self updateUI];
    if (![NSProcessInfo.processInfo.arguments containsObject:@"--background"]) [self showShelf:YES];
}
- (void)handleMouse:(NSEvent *)e own:(BOOL)own {
    if (e.type==NSEventTypeLeftMouseDown) {
        self.dragStartCount=[NSPasteboard pasteboardWithName:NSPasteboardNameDrag].changeCount; self.dragSession=NO;
        [self.dragTimer invalidate]; self.dragTimer=nil;
        if (!own) {
            self.dragDeadline=NSDate.timeIntervalSinceReferenceDate+120; __weak ShelfApp *weak=self;
            self.dragTimer=[NSTimer timerWithTimeInterval:.075 repeats:YES block:^(NSTimer *t){
                ShelfApp *a=weak; if (!a || !(NSEvent.pressedMouseButtons&1) || NSDate.timeIntervalSinceReferenceDate>a.dragDeadline) { [t invalidate]; a.dragTimer=nil; [a.catcherPanel orderOut:nil]; [a scheduleHide]; return; } [a probeDraggedFiles];
            }]; self.dragTimer.tolerance=.02; [NSRunLoop.mainRunLoop addTimer:self.dragTimer forMode:NSRunLoopCommonModes];
        }
        if (!own && self.panel.visible && !NSPointInRect(NSEvent.mouseLocation,self.panel.frame) && !NSPointInRect(NSEvent.mouseLocation,self.badgePanel.frame)) [self hideShelf]; return;
    }
    if (e.type==NSEventTypeLeftMouseUp) {
        [self.dragTimer invalidate]; self.dragTimer=nil; BOOL dragged=self.dragSession; self.dragSession=NO; [self.catcherPanel orderOut:nil];
        BOOL fileGesture=e.clickCount==2 || (e.modifierFlags&NSEventModifierFlagOption);
        if (!dragged && !self.draggingOut && fileGesture && NSPointInRect(NSEvent.mouseLocation,NSInsetRect(self.notchRect,-60,-8)) && !self.panel.visible) [self showShelf:YES];
        [self scheduleHide]; return;
    }
    if (own || self.draggingOut || self.copying) return;
    [self probeDraggedFiles];
}
- (void)probeDraggedFiles {
    if (self.draggingOut || self.copying || self.dragSession) return;
    NSTimeInterval now=NSDate.timeIntervalSinceReferenceDate; if (now-self.lastDragCheck<.045) return; self.lastDragCheck=now;
    NSPasteboard *pb=[NSPasteboard pasteboardWithName:NSPasteboardNameDrag];
    if (!self.dragSession && pb.changeCount==self.dragStartCount) return;
    NSRect hot=NSInsetRect(self.notchRect,-44,-14);
    if (NSPointInRect(NSEvent.mouseLocation,hot) && FileURLs(pb).count) { self.dragSession=YES; [self showShelf:NO]; [self.catcherPanel setFrame:NSInsetRect(self.notchRect,-24,0) display:NO]; [self.catcherPanel orderFrontRegardless]; }
}
- (void)startVolumeObserver {
    AudioObjectPropertySelector properties[]={kAudioDevicePropertyVolumeScalar,kAudioDevicePropertyMute,kAudioDevicePropertyDeviceIsRunningSomewhere};
    for (int i=0;i<3;i++) { AudioObjectPropertyAddress a={properties[i],i==2 ? kAudioObjectPropertyScopeGlobal : kAudioDevicePropertyScopeOutput,kAudioObjectPropertyElementWildcard}; if (self.audioDevice) AudioObjectRemovePropertyListener(self.audioDevice,&a,AudioChanged,(__bridge void *)self); }
    AudioDeviceID device=0; UInt32 size=sizeof(device); AudioObjectPropertyAddress output={kAudioHardwarePropertyDefaultOutputDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject,&output,0,NULL,&size,&device)!=noErr) return;
    self.audioDevice=device;
    for (int i=0;i<3;i++) { AudioObjectPropertyAddress a={properties[i],i==2 ? kAudioObjectPropertyScopeGlobal : kAudioDevicePropertyScopeOutput,kAudioObjectPropertyElementWildcard}; AudioObjectAddPropertyListener(device,&a,AudioChanged,(__bridge void *)self); }
}
- (void)refreshGeometry {
    NSRect notch=self.notchRect, a=[self alcoveBounds]; NSTimeInterval now=NSDate.timeIntervalSinceReferenceDate;
    if (!self.alcoveHasBounds) { self.previousAlcoveBounds=a; self.alcoveHasBounds=YES; }
    else if (!NSEqualRects(a,self.previousAlcoveBounds)) { self.quietUntil=now+.85; self.previousAlcoveBounds=a; }
    NSRect screen=self.notchedScreen.frame; CGFloat width=MIN(560,screen.size.width-32);
    // Always anchored to the notch, never pushed down by another app's window.
    CGFloat top=NSMaxY(notch);
    CGFloat height=self.store.items.count>4 ? 316 : 200;
    NSRect shelf=NSMakeRect(NSMidX(notch)-width/2,top-height,width,height);
    if (!NSEqualRects(self.panel.frame,shelf)) {
        [self.panel setFrame:shelf display:self.panel.visible];
        NSView *surface=self.panel.contentView;
        for (NSView *v in surface.subviews) {
            if ([v isKindOfClass:NSScrollView.class]) v.frame=NSMakeRect(6,12,548,height-66);
            else if ([v isKindOfClass:NSButton.class]) { NSRect r=v.frame; r.origin.y=height-37; v.frame=r; }
        }
        self.spinner.frame=NSMakeRect(488,height-32,16,16); [self.grid reload];
    }
    NSRect badge=NSMakeRect(NSMaxX(notch)-26,NSMinY(notch)-11,24,12); [self.badgePanel setFrame:badge display:NO];
    // Alcove keeps a 624x320 transparent host window even when idle. It is not visible HUD content.
    BOOL collision=(!NSIsEmptyRect(a) && a.size.height<140 && a.size.height>notch.size.height+8 && NSIntersectsRect(a,badge));
    BOOL yield=now<self.hudUntil && !self.dragSession && !self.copying;
    self.panel.alphaValue=yield ? 0 : 1; self.panel.ignoresMouseEvents=yield;
    BOOL show=self.store.items.count>0 && !self.panel.visible && !self.dragSession && now>=MAX(self.quietUntil,self.hudUntil) && !collision;
    if (show) [self.badgePanel orderFrontRegardless]; else [self.badgePanel orderOut:nil];
}
- (void)updateUI {
    self.titleLabel.stringValue=self.store.items.count ? [NSString stringWithFormat:@"文件托管台  ·  %lu",self.store.items.count] : @"文件托管台";
    self.badgeButton.title=@""; self.badgeButton.toolTip=[NSString stringWithFormat:@"%lu 个文件，点按打开",self.store.items.count];
    [self.grid reload];
    if ((self.store.items.count || self.panel.visible) && !self.coexistTimer) { self.coexistTimer=[NSTimer scheduledTimerWithTimeInterval:.5 target:self selector:@selector(tick:) userInfo:nil repeats:YES]; self.coexistTimer.tolerance=.2; }
    if (!self.store.items.count && !self.panel.visible && self.coexistTimer) { [self.coexistTimer invalidate]; self.coexistTimer=nil; }
    [self refreshGeometry];
}
- (void)tick:(NSTimer *)timer { [self refreshGeometry]; }
- (void)showShelf:(BOOL)activate {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideIfOutside) object:nil]; if (activate) self.panelPinned=YES;
    BOOL expanding=!self.panel.visible; [self updateUI]; [self.badgePanel orderOut:nil];
    NSRect expanded=self.panel.frame;
    if (expanding) [self.panel setFrame:self.notchRect display:NO];
    [self.panel orderFrontRegardless];
    if (expanding) [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c){ c.duration=.18; [self.panel.animator setFrame:expanded display:YES]; } completionHandler:nil];
    if (activate) { [NSApp activateIgnoringOtherApps:YES]; [self.panel makeKeyAndOrderFront:nil]; [self.panel makeFirstResponder:self.grid]; }
    if (!self.coexistTimer) { self.coexistTimer=[NSTimer scheduledTimerWithTimeInterval:.5 target:self selector:@selector(tick:) userInfo:nil repeats:YES]; self.coexistTimer.tolerance=.2; }
}
- (void)hideShelf { if (self.airDropActive) return; if(self.copying && self.uuReceiving){self.importCancelled=YES;[self message:@"正在停止UU接收…"];return;} if (self.copying || self.draggingOut) return; [self.panel orderOut:nil]; [self.catcherPanel orderOut:nil]; self.dragSession=NO; self.panelPinned=NO; [self updateUI]; }
- (void)scheduleHide {
    if (self.airDropActive) return;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideIfOutside) object:nil];
    NSTimeInterval delay=.85, now=NSDate.timeIntervalSinceReferenceDate;
    if (self.airDropHoldUntil>now) delay=MAX(delay,self.airDropHoldUntil-now);
    [self performSelector:@selector(hideIfOutside) withObject:nil afterDelay:delay];
}
- (void)hideIfOutside {
    if (self.airDropActive || self.copying || self.draggingOut || self.panelPinned) return;
    NSTimeInterval now=NSDate.timeIntervalSinceReferenceDate;
    if (self.airDropHoldUntil>now) { [self scheduleHide]; return; }
    if (!NSPointInRect(NSEvent.mouseLocation,self.panel.frame) && !NSPointInRect(NSEvent.mouseLocation,NSInsetRect(self.notchRect,-30,-8))) [self hideShelf];
}
- (void)close:(id)sender {
    if (self.airDropActive) {
        self.airDropActive=NO; [self.airDropWatchTimer invalidate]; self.airDropWatchTimer=nil; self.airDropService.delegate=nil; self.airDropService=nil;
    }
    self.airDropHoldUntil=0; [self hideShelf];
}
- (void)showError:(id)sender { NSAlert *a=[NSAlert new]; a.messageText=@"部分文件未能放入中转站"; a.informativeText=self.lastError ?: @"请重新拖入未完成的文件"; [a addButtonWithTitle:@"好"]; [a runModal]; }
- (void)toggle:(id)sender { if (self.panel.visible) [self hideShelf]; else [self showShelf:YES]; }
- (void)openFolder:(id)sender { [NSWorkspace.sharedWorkspace openURL:[self.store.root URLByAppendingPathComponent:@"Items" isDirectory:YES]]; }
- (void)airDrop:(id)sender {
    NSArray<NSURL *> *urls=self.grid.selectedURLs;
    if (!urls.count) { [self message:@"请先选择要隔空投送的文件"]; return; }
    NSSharingService *service=[NSSharingService sharingServiceNamed:NSSharingServiceNameSendViaAirDrop];
    if (!service) { [self message:@"当前系统未提供隔空投送服务"]; return; }
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideIfOutside) object:nil];
    self.airDropActive=YES; self.airDropHoldUntil=0; self.airDropWindowSeen=NO; self.airDropStartedAt=NSDate.timeIntervalSinceReferenceDate; self.airDropService=service; service.delegate=self; self.panelPinned=YES;
    [self.airDropWatchTimer invalidate]; self.airDropWatchTimer=[NSTimer scheduledTimerWithTimeInterval:.2 target:self selector:@selector(checkAirDropWindow:) userInfo:nil repeats:YES]; self.airDropWatchTimer.tolerance=.05;
    [self.panel orderFrontRegardless];
    [NSApp activateIgnoringOtherApps:YES];
    [service performWithItems:urls];
}
- (void)finishAirDropSession {
    if (!self.airDropActive) return;
    self.airDropActive=NO; [self.airDropWatchTimer invalidate]; self.airDropWatchTimer=nil; self.airDropService.delegate=nil; self.airDropService=nil; self.panelPinned=NO;
    self.airDropHoldUntil=NSDate.timeIntervalSinceReferenceDate+3.0;
    [self scheduleHide];
}
- (void)airDropAppDidBecomeActive:(NSNotification *)notification { if (self.airDropActive && self.airDropWindowSeen) [self checkAirDropWindow:nil]; }
- (void)sharingService:(NSSharingService *)sharingService didShareItems:(NSArray *)items { if (sharingService==self.airDropService && self.airDropWindowSeen) [self finishAirDropSession]; }
- (void)sharingService:(NSSharingService *)sharingService didFailToShareItems:(NSArray *)items error:(NSError *)error { if (sharingService==self.airDropService && self.airDropWindowSeen) [self finishAirDropSession]; }
- (void)checkAirDropWindow:(NSTimer *)timer {
    if (!self.airDropActive) { [timer invalidate]; return; }
    BOOL found=NO,visible=NO;
    for (NSWindow *window in NSApp.windows) {
        if (window==self.panel || window==self.badgePanel || window==self.catcherPanel) continue;
        NSString *title=window.title.lowercaseString ?: @"";
        NSString *className=NSStringFromClass(window.class).lowercaseString ?: @"";
        BOOL candidate=[title containsString:@"airdrop"] || [title containsString:@"隔空投送"] || [className containsString:@"shkremotewindow"];
        if (!candidate) continue;
        found=YES; visible |= window.isVisible;
    }
    if (visible) self.airDropWindowSeen=YES;
    NSTimeInterval age=NSDate.timeIntervalSinceReferenceDate-self.airDropStartedAt;
    if (self.airDropWindowSeen && (!found || !visible)) { [self finishAirDropSession]; return; }
    if (!self.airDropWindowSeen && age>15.0) [self finishAirDropSession];
}
- (void)message:(NSString *)s { self.subtitleLabel.stringValue=s ?: @""; self.grid.toolTip=s; self.panel.accessibilityHelp=s; [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(resetMessage) object:nil]; [self performSelector:@selector(resetMessage) withObject:nil afterDelay:5]; }
- (void)resetMessage { if (!self.copying) self.subtitleLabel.stringValue=@"拖入即保存 · 多文件 · ⌘C / ⌘V · Delete"; }
- (void)pasteFiles {
    if (self.copying) return;
    NSPasteboard *pb=NSPasteboard.generalPasteboard;
    NSArray *urls=FileURLs(pb); NSArray *payloads=urls.count ? @[] : ClipboardPayloads(pb);
    if (urls.count || payloads.count) [self importFiles:urls payloads:payloads];
    else { self.lastError=@"剪贴板没有可读取的文件、图片或文字。请在访达选中文件后按⌘C，或重新复制图片。"; self.statusButton.hidden=NO; self.statusButton.toolTip=self.lastError; [self message:self.lastError]; }
}
- (void)importFiles:(NSArray<NSURL *> *)urls { [self importFiles:urls payloads:@[]]; }
- (void)importFiles:(NSArray<NSURL *> *)urls payloads:(NSArray<NSDictionary *> *)payloads {
    if (self.copying || (!urls.count && !payloads.count)) return;
    NSMutableArray *markers=[NSMutableArray new],*ordinary=[NSMutableArray new];for(NSURL *url in urls){if(UUMarker(url))[markers addObject:url];else [ordinary addObject:url];}
    self.copying=YES; self.uuReceiving=markers.count>0; self.importCancelled=NO; self.dragSession=NO; self.lastError=nil; self.statusButton.hidden=YES; [self.catcherPanel orderOut:nil]; [self showShelf:NO]; [self.spinner startAnimation:nil];
    [self message:self.uuReceiving ? @"正在接收UU文件，传输完成后会自动显示原文件" : [NSString stringWithFormat:@"正在保存 %lu 个文件…",urls.count+payloads.count]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        // The worker owns its model while copying; the UI keeps an immutable-in-practice
        // prior model until the whole batch has completed, avoiding cross-thread array mutation.
        NSError *loadError=nil; ShelfStore *worker=[[ShelfStore alloc] initWithRoot:self.store.root error:&loadError];
        NSMutableArray *errors=[NSMutableArray new];
        if (loadError) [errors addObject:loadError.localizedDescription];
        NSMutableArray *added=[NSMutableArray new];
        if (worker) {
            [added addObjectsFromArray:[worker importURLs:ordinary errors:errors]]; [added addObjectsFromArray:[worker importPayloads:payloads errors:errors]];
            if(markers.count){NSError *receiveError=nil;NSURL *receiving=nil;NSArray *received=ReceiveUUFiles(markers,worker.root,180,^BOOL{return self.importCancelled;},&receiving,&receiveError);
                if(received.count) [added addObjectsFromArray:[worker adoptUUFiles:received fromDirectory:receiving errors:errors]];
                else [errors addObject:receiveError.localizedDescription ?: @"UU文件未接收完成，占位文件未加入托管台"];
            }
        }
        dispatch_async(dispatch_get_main_queue(),^{ if (worker) self.store=worker; self.copying=NO; self.uuReceiving=NO; [self.spinner stopAnimation:nil]; [self.grid.selection removeAllIndexes];
            NSUInteger count=self.store.items.count; if (added.count) [self.grid.selection addIndexesInRange:NSMakeRange(count-added.count,added.count)];
            self.lastError=errors.count ? [errors componentsJoinedByString:@"\n"] : nil; self.statusButton.hidden=!errors.count; self.statusButton.toolTip=self.lastError;
            [self updateUI]; if(self.importCancelled) [self hideShelf]; else { [self.panel makeKeyAndOrderFront:nil]; [self.panel makeFirstResponder:self.grid]; }
            [self message:errors.count ? [NSString stringWithFormat:@"已保存 %lu 个，部分未完成：%@",added.count,errors.firstObject] : [NSString stringWithFormat:@"已保存 %lu 个文件到本机",added.count]]; [self scheduleHide];
        });
    });
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag { [self showShelf:YES]; return YES; }
- (void)applicationWillTerminate:(NSNotification *)n { [self.coexistTimer invalidate]; [self.dragTimer invalidate]; if (self.globalMonitor) [NSEvent removeMonitor:self.globalMonitor]; if (self.localMonitor) [NSEvent removeMonitor:self.localMonitor]; if (self.lockFD>0) close(self.lockFD); }
- (void)woke:(NSNotification *)n { [self refreshGeometry]; }
- (void)screenChanged:(NSNotification *)n { self.alcoveHasBounds=NO; [self refreshGeometry]; }
@end

static int SelfTest(NSString *path) {
    NSFileManager *fm=NSFileManager.defaultManager; NSURL *root=[NSURL fileURLWithPath:path isDirectory:YES];
    NSError *err=nil; if ([fm fileExistsAtPath:path]) { fprintf(stderr,"self-test requires a new test directory\n"); return 2; }
    [fm createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:&err];
    NSURL *a=[root URLByAppendingPathComponent:@"原件甲.txt"],*b=[root URLByAppendingPathComponent:@"原件乙.txt"],*folder=[root URLByAppendingPathComponent:@"文件夹" isDirectory:YES];
    [@"original alpha α" writeToURL:a atomically:YES encoding:NSUTF8StringEncoding error:&err]; [@"original beta 中文" writeToURL:b atomically:YES encoding:NSUTF8StringEncoding error:&err]; [fm createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:&err]; [@"inside" writeToURL:[folder URLByAppendingPathComponent:@"内层.txt"] atomically:YES encoding:NSUTF8StringEncoding error:&err];
    ShelfStore *store=[[ShelfStore alloc] initWithRoot:[root URLByAppendingPathComponent:@"vault"] error:&err]; NSMutableArray *errors=[NSMutableArray new]; NSArray *added=[store importURLs:@[a,b,folder,a] errors:errors];
    BOOL pass=store && !errors.count && added.count==4 && store.items.count==4;
    NSURL *first=[store urlForItem:added.firstObject]; pass &= [[NSData dataWithContentsOfURL:a] isEqual:[NSData dataWithContentsOfURL:first]];
    [@"source changed" writeToURL:a atomically:YES encoding:NSUTF8StringEncoding error:&err]; pass &= ![[NSData dataWithContentsOfURL:a] isEqual:[NSData dataWithContentsOfURL:first]];
    ShelfStore *again=[[ShelfStore alloc] initWithRoot:store.root error:&err]; pass &= again.items.count==4;
    pass &= [again urlForItem:@{@"id":@"../bad",@"name":@"escape"}]==nil;
    pass &= [again urlForItem:@{@"id":NSUUID.UUID.UUIDString,@"name":@"../../escape"}]==nil;
    NSURL *link=[root URLByAppendingPathComponent:@"symbolic-link"]; [fm createSymbolicLinkAtURL:link withDestinationURL:b error:&err]; NSMutableArray *linkErrors=[NSMutableArray new]; pass &= [again importURLs:@[link] errors:linkErrors].count==0 && linkErrors.count>0;
    BOOL originalBefore=[fm fileExistsAtPath:b.path]; NSDictionary *toDelete=again.items[1]; pass &= [again removeIDs:[NSSet setWithObject:toDelete[@"id"]] error:&err]; pass &= again.items.count==3 && originalBefore && [fm fileExistsAtPath:b.path];
    // Restore an interrupted index by recovering an already complete UUID copy.
    [fm removeItemAtURL:[store.root URLByAppendingPathComponent:@"index.json"] error:nil]; ShelfStore *recover=[[ShelfStore alloc] initWithRoot:store.root error:&err]; pass &= recover.items.count==3;
    NSMutableArray *parentErrors=[NSMutableArray new]; BOOL parentRejected=[recover importURLs:@[root] errors:parentErrors].count==0 && parentErrors.count>0; pass &= parentRejected;
    NSDictionary *results=@{@"passed":@(pass),@"multi_file_and_folder_import":@(added.count==4),@"restart_items":@(recover.items.count),@"original_preserved":@([fm fileExistsAtPath:b.path]),@"symlink_rejected":@(linkErrors.count>0),@"recursive_parent_rejected":@(parentRejected),@"errors":errors};
    NSData *out=[NSJSONSerialization dataWithJSONObject:results options:NSJSONWritingPrettyPrinted error:nil]; [out writeToURL:[root URLByAppendingPathComponent:@"results.json"] atomically:YES]; fwrite(out.bytes,1,out.length,stdout); return pass ? 0 : 1;
}

static int ClipboardTest(NSString *path) {
    NSFileManager *fm=NSFileManager.defaultManager; if ([fm fileExistsAtPath:path]) return 2;
    NSURL *root=[NSURL fileURLWithPath:path isDirectory:YES]; NSError *err=nil;
    [fm createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:&err];
    NSURL *a=[root URLByAppendingPathComponent:@"原文件-甲.txt"],*b=[root URLByAppendingPathComponent:@"原文件-乙.txt"];
    [@"alpha" writeToURL:a atomically:YES encoding:NSUTF8StringEncoding error:&err]; [@"beta" writeToURL:b atomically:YES encoding:NSUTF8StringEncoding error:&err];
    NSPasteboard *pb=[NSPasteboard pasteboardWithUniqueName]; NSMutableDictionary *r=[NSMutableDictionary new];
    [pb writeObjects:@[a,b]]; r[@"modern_two_file_urls"]=@(FileURLs(pb).count==2);
    [pb addTypes:@[@"NSFilenamesPboardType"] owner:nil]; [pb setPropertyList:@[a.path,b.path] forType:@"NSFilenamesPboardType"];
    r[@"combined_modern_legacy_no_duplicate"]=@(FileURLs(pb).count==2);
    [pb clearContents]; [pb writeObjects:@[a.fileReferenceURL,b.fileReferenceURL]]; [pb addTypes:@[@"NSFilenamesPboardType"] owner:nil]; [pb setPropertyList:@[a.path,b.path] forType:@"NSFilenamesPboardType"];
    r[@"file_reference_and_path_no_duplicate"]=@(FileURLs(pb).count==2);
    [pb declareTypes:@[@"NSFilenamesPboardType"] owner:nil]; [pb setPropertyList:@[a.path,b.path] forType:@"NSFilenamesPboardType"]; r[@"legacy_two_filenames"]=@(FileURLs(pb).count==2);
    NSBitmapImageRep *im=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:2 pixelsHigh:2 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    for (int x=0;x<2;x++) for (int y=0;y<2;y++) [im setColor:[NSColor colorWithDeviceRed:.2 green:.8 blue:.7 alpha:1] atX:x y:y];
    NSData *png=[im representationUsingType:NSBitmapImageFileTypePNG properties:@{}]; NSPasteboardItem *item=[NSPasteboardItem new]; [item setData:png forType:NSPasteboardTypePNG];
    [pb clearContents]; [pb writeObjects:@[item]]; NSArray *images=ClipboardPayloads(pb); r[@"png_read_without_file_url"]=@(FileURLs(pb).count==0 && images.count==1 && [images[0][@"data"] isEqual:png]);
    ShelfStore *store=[[ShelfStore alloc] initWithRoot:[root URLByAppendingPathComponent:@"vault"] error:&err]; NSMutableArray *errors=[NSMutableArray new];
    NSArray *added=[store importPayloads:images errors:errors]; r[@"png_exact_bytes"]=@(added.count==1 && [[NSData dataWithContentsOfURL:[store urlForItem:added.firstObject]] isEqual:png]);
    [pb clearContents]; [pb writeObjects:@[@"中文文本 β"]]; NSArray *texts=ClipboardPayloads(pb); added=[store importPayloads:texts errors:errors];
    r[@"text_utf8_roundtrip"]=@(added.count==1 && [[NSString stringWithContentsOfURL:[store urlForItem:added.firstObject] encoding:NSUTF8StringEncoding error:&err] isEqual:@"中文文本 β"]);
    [pb clearContents]; r[@"empty_rejected"]=@(ClipboardPayloads(pb).count==0 && FileURLs(pb).count==0);
    item=[NSPasteboardItem new]; [item setString:@"public.data" forType:@"com.apple.pasteboard.promised-file-content-type"]; [item setData:png forType:NSPasteboardTypePNG]; [pb writeObjects:@[item]];
    r[@"promised_file_preview_not_mistaken_for_file"]=@(ClipboardPayloads(pb).count==0);
    ShelfStore *again=[[ShelfStore alloc] initWithRoot:store.root error:&err]; r[@"restart_payloads_persist"]=@(again.items.count==2);
    r[@"originals_preserved"]=@([fm fileExistsAtPath:a.path] && [fm fileExistsAtPath:b.path]);
    [pb releaseGlobally]; BOOL pass=!errors.count; for (NSString *key in r) pass &= [r[key] boolValue];
    r[@"passed"]=@(pass); r[@"general_clipboard_touched"]=@NO;
    NSData *data=[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted error:nil]; [data writeToURL:[root URLByAppendingPathComponent:@"results.json"] atomically:YES]; fwrite(data.bytes,1,data.length,stdout); return pass ? 0 : 1;
}

static int UUReceiverTest(NSString *path) {
    NSFileManager *fm=NSFileManager.defaultManager;if([fm fileExistsAtPath:path])return 2;
    NSURL *root=[NSURL fileURLWithPath:path isDirectory:YES],*sources=[root URLByAppendingPathComponent:@"sources" isDirectory:YES];NSError *err=nil;
    [fm createDirectoryAtURL:sources withIntermediateDirectories:YES attributes:nil error:&err];
    NSURL *marker=[sources URLByAppendingPathComponent:[@".uuremote_LOCAL_TEST_" stringByAppendingString:NSUUID.UUID.UUIDString]];[[NSData data] writeToURL:marker atomically:YES];
    ShelfStore *store=[[ShelfStore alloc] initWithRoot:[root URLByAppendingPathComponent:@"vault"] error:&err];NSMutableDictionary *r=[NSMutableDictionary new];
    NSData *payload=[@"unchanged remote bytes 中文 β" dataUsingEncoding:NSUTF8StringEncoding];dispatch_semaphore_t committed=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSTimeInterval stop=NSDate.timeIntervalSinceReferenceDate+4;NSURL *stage=nil;
        while(NSDate.timeIntervalSinceReferenceDate<stop){for(NSURL *d in [fm contentsOfDirectoryAtURL:store.root includingPropertiesForKeys:nil options:0 error:nil])if([d.lastPathComponent hasPrefix:@".uu-receive-"] && [fm fileExistsAtPath:[d URLByAppendingPathComponent:marker.lastPathComponent].path]){stage=d;break;}if(stage)break;[NSThread sleepForTimeInterval:.02];}
        if(!stage)return;
        NSURL *doc=[stage URLByAppendingPathComponent:@"原文件.docx"];[[NSData data] writeToURL:doc atomically:YES];[NSThread sleepForTimeInterval:.2];
        [payload writeToURL:doc atomically:YES];[payload writeToURL:[stage URLByAppendingPathComponent:@"第二份.txt"] atomically:YES];[[NSData data] writeToURL:[stage URLByAppendingPathComponent:@"空白.txt"] atomically:YES];
        NSURL *folder=[stage URLByAppendingPathComponent:@"文件夹" isDirectory:YES];[fm createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];[payload writeToURL:[folder URLByAppendingPathComponent:@"内层.txt"] atomically:YES];
        [NSThread sleepForTimeInterval:.25];[fm removeItemAtURL:[stage URLByAppendingPathComponent:marker.lastPathComponent] error:nil];dispatch_semaphore_signal(committed);
    });
    NSURL *stage=nil;NSArray *received=ReceiveUUFiles(@[marker],store.root,6,^BOOL{return NO;},&stage,&err);
    r[@"waited_for_producer_commit"]=@(dispatch_semaphore_wait(committed,DISPATCH_TIME_NOW)==0);r[@"multi_files_and_folder_received"]=@(received.count==4);
    NSMutableArray *errors=[NSMutableArray new];NSArray *added=[store adoptUUFiles:received ?: @[] fromDirectory:stage errors:errors];
    r[@"four_final_objects_indexed"]=@(added.count==4 && !errors.count);BOOL names=YES,bytes=NO;
    for(NSDictionary *item in store.items){names &= !UUName(item[@"name"]);if([item[@"name"] isEqual:@"原文件.docx"])bytes=[[NSData dataWithContentsOfURL:[store urlForItem:item]] isEqual:payload];}
    r[@"placeholder_never_indexed"]=@(names);r[@"original_filename_and_bytes"]=@(bytes);r[@"staging_moved_not_duplicated"]=@(![fm fileExistsAtPath:stage.path]);
    NSURL *timeoutStage=nil;NSError *timeoutError=nil;NSArray *none=ReceiveUUFiles(@[marker],store.root,.2,^BOOL{return NO;},&timeoutStage,&timeoutError);
    r[@"timeout_does_not_publish_marker"]=@(!none.count && timeoutError && store.items.count==4 && [fm fileExistsAtPath:timeoutStage.path]);
    NSError *cancelError=nil;none=ReceiveUUFiles(@[marker],store.root,6,^BOOL{return YES;},NULL,&cancelError);r[@"cancel_is_bounded"]=@(!none.count && cancelError);
    NSMutableArray *rejections=[NSMutableArray new];r[@"direct_placeholder_import_rejected"]=@([store importURLs:@[marker] errors:rejections].count==0 && rejections.count>0);
    NSDictionary *doc=nil;for(NSDictionary *item in store.items)if([item[@"name"] isEqual:@"原文件.docx"])doc=item;
    NSURL *sidecar=[[store urlForItem:doc].URLByDeletingLastPathComponent URLByAppendingPathComponent:@"稍后到达.txt"];[payload writeToURL:sidecar atomically:YES];
    BOOL deleted=[store removeIDs:[NSSet setWithObject:doc[@"id"]] error:&err];r[@"deleting_item_preserves_late_arrivals"]=@(deleted && [[NSData dataWithContentsOfURL:sidecar] isEqual:payload]);
    NSURL *pending=[store.root URLByAppendingPathComponent:[@".uu-receive-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];[fm createDirectoryAtURL:pending withIntermediateDirectories:NO attributes:nil error:&err];[payload writeToURL:[pending URLByAppendingPathComponent:@"恢复.txt"] atomically:YES];
    ShelfStore *again=[[ShelfStore alloc] initWithRoot:store.root error:&err];BOOL recovered=NO;for(NSDictionary *item in again.items)if([item[@"name"] isEqual:@"恢复.txt"])recovered=[[NSData dataWithContentsOfURL:[again urlForItem:item]] isEqual:payload];r[@"completed_receipt_recovers_after_restart"]=@(recovered);
    r[@"general_clipboard_touched"]=@NO;BOOL pass=YES;for(NSString *key in r)if(![key isEqual:@"general_clipboard_touched"])pass &= [r[key] boolValue];r[@"passed"]=@(pass);
    NSData *data=[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted error:nil];[data writeToURL:[root URLByAppendingPathComponent:@"results.json"] atomically:YES];fwrite(data.bytes,1,data.length,stdout);return pass ? 0 : 1;
}

int main(int argc,const char **argv) {
    @autoreleasepool {
        if (argc==3 && strcmp(argv[1],"--self-test")==0) return SelfTest([NSString stringWithUTF8String:argv[2]]);
        if (argc==3 && strcmp(argv[1],"--clipboard-test")==0) return ClipboardTest([NSString stringWithUTF8String:argv[2]]);
        if (argc==3 && strcmp(argv[1],"--uu-test")==0) return UUReceiverTest([NSString stringWithUTF8String:argv[2]]);
        if (argc==2 && strcmp(argv[1],"--geometry")==0) {
            [NSApplication sharedApplication]; ShelfApp *probe=[ShelfApp new];
            NSRunningApplication *alcove=[NSRunningApplication runningApplicationsWithBundleIdentifier:AlcoveID].firstObject;
            NSRect bounds=probe.alcoveBounds;
            NSDictionary *d=@{@"screen":NSStringFromRect(probe.notchedScreen.frame),@"safe_top":@(probe.notchedScreen.safeAreaInsets.top),@"notch":NSStringFromRect(probe.notchRect),@"alcove":NSStringFromRect(bounds),@"alcove_window_level":@(probe.alcoveWindowLevel),@"screen_saver_level":@(NSScreenSaverWindowLevel),@"alcove_hidden":@(alcove.hidden),@"drawer_top":@(NSMaxY(probe.notchRect))};
            NSData *data=[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:nil]; fwrite(data.bytes,1,data.length,stdout); return 0;
        }
        // Launching the login helper and opening the application must never create two stores.
        if ([NSRunningApplication runningApplicationsWithBundleIdentifier:AppID].count>1) return 0;
        NSApplication *app=[NSApplication sharedApplication]; ShelfApp *delegate=[ShelfApp new]; app.delegate=delegate; [app run];
    }
    return 0;
}
