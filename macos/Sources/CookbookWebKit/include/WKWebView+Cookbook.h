#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WKWebView (Cookbook)

- (BOOL)cookbookHasPagination;
- (void)cookbookSetPaginationMode:(NSInteger)mode
                       pageLength:(CGFloat)pageLength
                              gap:(CGFloat)gap
                      likeColumns:(BOOL)likeColumns;
@property (nonatomic, readonly) NSUInteger cookbookPageCount;
- (void)cookbookSetWhiteBackground;
/// Calls WebKit's next-paint hook if present; otherwise runs the block immediately.
- (void)cookbookDoAfterNextPaint:(void (^)(void))block NS_SWIFT_NAME(cookbookOnNextPaint(_:));
/// Vector PDF of `rect` in document coordinates (not the scrolled view).
- (void)cookbookCapturePDFRect:(CGRect)rect
                    completion:(void (^)(NSData *_Nullable data, NSError *_Nullable error))completion
    NS_SWIFT_NAME(cookbookCapturePDF(rect:_:));
/// One print job to a PDF file (Calibre-style). Paper size is in points.
/// `fromPage`/`toPage` are 1-based inclusive; pass 0,0 for all pages.
- (void)cookbookPrintToFile:(NSURL *)url
                  paperSize:(NSSize)paperSize
                   fromPage:(NSInteger)fromPage
                     toPage:(NSInteger)toPage
                 completion:(void (^)(BOOL success, NSError *_Nullable error))completion
    NS_SWIFT_NAME(cookbookPrint(to:paperSize:from:to:_:));

@end

NS_ASSUME_NONNULL_END
