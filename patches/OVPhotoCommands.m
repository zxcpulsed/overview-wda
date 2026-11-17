
// ===================== OverView: импорт в альбом и очистка (PhotoKit) =====================
// Дописывается в конец WebDriverAgentLib/Commands/FBCustomCommands.m при сборке.
// Маршруты (без сессии):
//   POST /overview/auth                      — запросить доступ к фото (первый раз iOS покажет окно)
//   POST /overview/import {"name": "x.mp4"}  — файл из <контейнер WDA>/Documents/x.mp4 в альбом OverView
//   POST /overview/clean                     — удалить из медиатеки всё содержимое альбома OverView
//   GET  /overview/status                    — {"auth": n, "busy": bool, "last": {...}} — итог последней операции
// Импорт и удаление идут асинхронно: удаление ждёт системного подтверждения, а WDA в это время должен
// отвечать на другие запросы (программа нажимает «Удалить» через обычный alert API).

@import Photos;

static NSString *const OVAlbumTitle = @"OverView";
static NSMutableDictionary *OVLast = nil;
static BOOL OVBusy = NO;

@interface OVPhotoCommands : NSObject <FBCommandHandler>
@end

@implementation OVPhotoCommands

+ (NSArray *)routes
{
  return @[
    [[FBRoute POST:@"/overview/auth"].withoutSession respondWithTarget:self action:@selector(handleAuth:)],
    [[FBRoute POST:@"/overview/import"].withoutSession respondWithTarget:self action:@selector(handleImport:)],
    [[FBRoute POST:@"/overview/clean"].withoutSession respondWithTarget:self action:@selector(handleClean:)],
    [[FBRoute GET:@"/overview/status"].withoutSession respondWithTarget:self action:@selector(handleStatus:)],
  ];
}

+ (void)ovFinish:(NSString *)op ok:(BOOL)ok info:(NSString *)info
{
  @synchronized (self) {
    OVLast = [@{@"op": op, @"ok": @(ok), @"info": info ?: @"", @"ts": @([[NSDate date] timeIntervalSince1970])} mutableCopy];
    OVBusy = NO;
  }
}

+ (PHAssetCollection *)ovFindAlbum
{
  PHFetchOptions *opts = [PHFetchOptions new];
  opts.predicate = [NSPredicate predicateWithFormat:@"title == %@", OVAlbumTitle];
  PHFetchResult<PHAssetCollection *> *r =
    [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                                             subtype:PHAssetCollectionSubtypeAlbumRegular
                                             options:opts];
  return r.firstObject;
}

+ (PHAssetCollection *)ovEnsureAlbum:(NSError **)error
{
  PHAssetCollection *album = [self ovFindAlbum];
  if (album) {
    return album;
  }
  __block NSString *localId = nil;
  BOOL ok = [[PHPhotoLibrary sharedPhotoLibrary] performChangesAndWait:^{
    PHAssetCollectionChangeRequest *req =
      [PHAssetCollectionChangeRequest creationRequestForAssetCollectionWithTitle:OVAlbumTitle];
    localId = req.placeholderForCreatedAssetCollection.localIdentifier;
  } error:error];
  if (!ok || !localId) {
    return nil;
  }
  return [PHAssetCollection fetchAssetCollectionsWithLocalIdentifiers:@[localId] options:nil].firstObject;
}

+ (id<FBResponsePayload>)handleStatus:(FBRouteRequest *)request
{
  NSInteger auth = (NSInteger)[PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
  PHAssetCollection *album = auth == PHAuthorizationStatusAuthorized ? [self ovFindAlbum] : nil;
  NSUInteger count = album ? [PHAsset fetchAssetsInAssetCollection:album options:nil].count : 0;
  @synchronized (self) {
    return FBResponseWithObject(@{
      @"auth": @(auth),
      @"busy": @(OVBusy),
      @"album": @(album != nil),
      @"count": @(count),
      @"last": OVLast ?: @{},
    });
  }
}

+ (id<FBResponsePayload>)handleAuth:(FBRouteRequest *)request
{
  PHAuthorizationStatus st = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
  if (st == PHAuthorizationStatusNotDetermined) {
    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite handler:^(PHAuthorizationStatus s) {
      [self ovFinish:@"auth" ok:(s == PHAuthorizationStatusAuthorized) info:[NSString stringWithFormat:@"%ld", (long)s]];
    }];
    return FBResponseWithObject(@{@"auth": @(st), @"requested": @YES});
  }
  return FBResponseWithObject(@{@"auth": @(st), @"requested": @NO});
}

+ (id<FBResponsePayload>)handleImport:(FBRouteRequest *)request
{
  NSString *name = request.arguments[@"name"];
  if (![name isKindOfClass:NSString.class] || name.length == 0 || [name containsString:@"/"]) {
    return FBResponseWithUnknownErrorFormat(@"name required");
  }
  NSString *path = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:name];
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    return FBResponseWithUnknownErrorFormat(@"file not found: %@", path);
  }
  @synchronized (self) {
    if (OVBusy) {
      return FBResponseWithUnknownErrorFormat(@"busy");
    }
    OVBusy = YES;
  }
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError *err = nil;
    PHAssetCollection *album = [self ovEnsureAlbum:&err];
    if (!album) {
      [self ovFinish:@"import" ok:NO info:err.localizedDescription ?: @"album error"];
      return;
    }
    NSURL *url = [NSURL fileURLWithPath:path];
    NSString *ext = path.pathExtension.lowercaseString;
    BOOL isVideo = [@[@"mp4", @"mov", @"m4v"] containsObject:ext];
    BOOL ok = [[PHPhotoLibrary sharedPhotoLibrary] performChangesAndWait:^{
      PHAssetChangeRequest *req = isVideo
        ? [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:url]
        : [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:url];
      PHAssetCollectionChangeRequest *add = [PHAssetCollectionChangeRequest changeRequestForAssetCollection:album];
      if (req.placeholderForCreatedAsset) {
        [add addAssets:@[req.placeholderForCreatedAsset]];
      }
    } error:&err];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    [self ovFinish:@"import" ok:ok info:ok ? name : (err.localizedDescription ?: @"import error")];
  });
  return FBResponseWithObject(@{@"started": @YES});
}

+ (id<FBResponsePayload>)handleClean:(FBRouteRequest *)request
{
  @synchronized (self) {
    if (OVBusy) {
      return FBResponseWithUnknownErrorFormat(@"busy");
    }
    OVBusy = YES;
  }
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    PHAssetCollection *album = [self ovFindAlbum];
    if (!album) {
      [self ovFinish:@"clean" ok:YES info:@"no album"];
      return;
    }
    PHFetchResult<PHAsset *> *assets = [PHAsset fetchAssetsInAssetCollection:album options:nil];
    if (assets.count == 0) {
      [self ovFinish:@"clean" ok:YES info:@"0"];
      return;
    }
    NSUInteger n = assets.count;
    NSError *err = nil;
    // iOS покажет системное подтверждение удаления — его нажимает программа через alert API
    BOOL ok = [[PHPhotoLibrary sharedPhotoLibrary] performChangesAndWait:^{
      [PHAssetChangeRequest deleteAssets:assets];
    } error:&err];
    [self ovFinish:@"clean" ok:ok info:ok ? [NSString stringWithFormat:@"%lu", (unsigned long)n]
                                       : (err.localizedDescription ?: @"clean error")];
  });
  return FBResponseWithObject(@{@"started": @YES});
}

@end
