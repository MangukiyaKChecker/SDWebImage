/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDAnimatedImageView.h"

#if SD_UIKIT || SD_MAC

#import "UIImage+Metadata.h"
#import "NSImage+Compatibility.h"
#import <mach/mach.h>
#import <objc/runtime.h>

#if SD_MAC
#import <CoreVideo/CoreVideo.h>
static CVReturn renderCallback(CVDisplayLinkRef displayLink, const CVTimeStamp *inNow, const CVTimeStamp *inOutputTime, CVOptionFlags flagsIn, CVOptionFlags *flagsOut, void *displayLinkContext);
#endif

static NSUInteger SDDeviceTotalMemory() {
    return (NSUInteger)[[NSProcessInfo processInfo] physicalMemory];
}

static NSUInteger SDDeviceFreeMemory() {
    mach_port_t host_port = mach_host_self();
    mach_msg_type_number_t host_size = sizeof(vm_statistics_data_t) / sizeof(integer_t);
    vm_size_t page_size;
    vm_statistics_data_t vm_stat;
    kern_return_t kern;
    
    kern = host_page_size(host_port, &page_size);
    if (kern != KERN_SUCCESS) return 0;
    kern = host_statistics(host_port, HOST_VM_INFO, (host_info_t)&vm_stat, &host_size);
    if (kern != KERN_SUCCESS) return 0;
    return vm_stat.free_count * page_size;
}

@interface SDWeakProxy : NSProxy

@property (nonatomic, weak, readonly) id target;

- (instancetype)initWithTarget:(id)target;
+ (instancetype)proxyWithTarget:(id)target;

@end

@implementation SDWeakProxy

- (instancetype)initWithTarget:(id)target {
    _target = target;
    return self;
}

+ (instancetype)proxyWithTarget:(id)target {
    return [[SDWeakProxy alloc] initWithTarget:target];
}

- (id)forwardingTargetForSelector:(SEL)selector {
    return _target;
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    void *null = NULL;
    [invocation setReturnValue:&null];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [NSObject instanceMethodSignatureForSelector:@selector(init)];
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    return [_target respondsToSelector:aSelector];
}

- (BOOL)isEqual:(id)object {
    return [_target isEqual:object];
}

- (NSUInteger)hash {
    return [_target hash];
}

- (Class)superclass {
    return [_target superclass];
}

- (Class)class {
    return [_target class];
}

- (BOOL)isKindOfClass:(Class)aClass {
    return [_target isKindOfClass:aClass];
}

- (BOOL)isMemberOfClass:(Class)aClass {
    return [_target isMemberOfClass:aClass];
}

- (BOOL)conformsToProtocol:(Protocol *)aProtocol {
    return [_target conformsToProtocol:aProtocol];
}

- (BOOL)isProxy {
    return YES;
}

- (NSString *)description {
    return [_target description];
}

- (NSString *)debugDescription {
    return [_target debugDescription];
}

@end

@interface SDAnimatedImageView () <CALayerDelegate>

@property (nonatomic, strong, readwrite) UIImage *currentFrame;
@property (nonatomic, assign, readwrite) NSUInteger currentFrameIndex;
@property (nonatomic, assign, readwrite) NSUInteger currentLoopCount;
@property (nonatomic, assign) NSUInteger totalFrameCount;
@property (nonatomic, assign) NSUInteger totalLoopCount;
@property (nonatomic, strong) UIImage<SDAnimatedImage> *animatedImage;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, UIImage *> *frameBuffer;
@property (nonatomic, assign) NSTimeInterval currentTime;
@property (nonatomic, assign) BOOL bufferMiss;
@property (nonatomic, assign) BOOL shouldAnimate;
@property (nonatomic, assign) BOOL isProgressive;
@property (nonatomic, assign) NSUInteger maxBufferCount;
@property (nonatomic, strong) NSOperationQueue *fetchQueue;
@property (nonatomic, strong) dispatch_semaphore_t lock;
@property (nonatomic, assign) CGFloat animatedImageScale;
#if SD_MAC
@property (nonatomic, assign) CVDisplayLinkRef displayLink;
#else
@property (nonatomic, strong) CADisplayLink *displayLink;
#endif
// Layer-backed NSImageView use a subview of `NSImageViewContainerView` to do actual layer rendering. We use this layer instead of `self.layer` during animated image rendering.
#if SD_MAC
@property (nonatomic, strong, readonly) CALayer *imageViewLayer;
#endif

@end

@implementation SDAnimatedImageView
#if SD_UIKIT
@dynamic animationRepeatCount;
#else
@dynamic imageViewLayer;
#endif

#pragma mark - Initializers

#if SD_MAC
+ (instancetype)imageViewWithImage:(NSImage *)image
{
    NSRect frame = NSMakeRect(0, 0, image.size.width, image.size.height);
    SDAnimatedImageView *imageView = [[SDAnimatedImageView alloc] initWithFrame:frame];
    [imageView setImage:image];
    return imageView;
}
#else
// -initWithImage: isn't documented as a designated initializer of UIImageView, but it actually seems to be.
// Using -initWithImage: doesn't call any of the other designated initializers.
- (instancetype)initWithImage:(UIImage *)image
{
    self = [super initWithImage:image];
    if (self) {
        [self commonInit];
    }
    return self;
}

// -initWithImage:highlightedImage: also isn't documented as a designated initializer of UIImageView, but it doesn't call any other designated initializers.
- (instancetype)initWithImage:(UIImage *)image highlightedImage:(UIImage *)highlightedImage
{
    self = [super initWithImage:image highlightedImage:highlightedImage];
    if (self) {
        [self commonInit];
    }
    return self;
}
#endif

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder
{
    self = [super initWithCoder:aDecoder];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)commonInit
{
    self.shouldCustomLoopCount = NO;
    self.shouldIncrementalLoad = YES;
    self.lock = dispatch_semaphore_create(1);
#if SD_MAC
    self.wantsLayer = YES;
    // Default value from `NSImageView`
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    self.imageScaling = NSImageScaleProportionallyDown;
    self.imageAlignment = NSImageAlignCenter;
#endif
#if SD_UIKIT
    self.runLoopMode = [[self class] defaultRunLoopMode];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveMemoryWarning:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
#endif
}

- (void)resetAnimatedImage
{
    self.animatedImage = nil;
    self.totalFrameCount = 0;
    self.totalLoopCount = 0;
    self.currentFrame = nil;
    self.currentFrameIndex = 0;
    self.currentLoopCount = 0;
    self.currentTime = 0;
    self.bufferMiss = NO;
    self.shouldAnimate = NO;
    self.isProgressive = NO;
    self.maxBufferCount = 0;
    self.animatedImageScale = 1;
    [_fetchQueue cancelAllOperations];
    _fetchQueue = nil;
    LOCKBLOCK({
        [_frameBuffer removeAllObjects];
        _frameBuffer = nil;
    });
}

- (void)resetProgressiveImage
{
    self.animatedImage = nil;
    self.totalFrameCount = 0;
    self.totalLoopCount = 0;
    // preserve current state
    self.shouldAnimate = NO;
    self.isProgressive = YES;
    self.maxBufferCount = 0;
    self.animatedImageScale = 1;
    // preserve buffer cache
}

#pragma mark - Accessors
#pragma mark Public

- (void)setImage:(UIImage *)image
{
    if (self.image == image) {
        return;
    }
    
    // Check Progressive rendering
    [self updateIsProgressiveWithImage:image];
    
    if (self.isProgressive) {
        // Reset all value, but keep current state
        [self resetProgressiveImage];
    } else {
        // Stop animating
        [self stopAnimating];
        // Reset all value
        [self resetAnimatedImage];
    }
    
    // We need call super method to keep function. This will impliedly call `setNeedsDisplay`. But we have no way to avoid this when using animated image. So we call `setNeedsDisplay` again at the end.
    super.image = image;
    if ([image conformsToProtocol:@protocol(SDAnimatedImage)]) {
        NSUInteger animatedImageFrameCount = ((UIImage<SDAnimatedImage> *)image).animatedImageFrameCount;
        // Check the frame count
        if (animatedImageFrameCount <= 1) {
            return;
        }
        // If progressive rendering is disabled but animated image is incremental. Only show poster image
        if (!self.isProgressive && image.sd_isIncremental) {
            return;
        }
        self.animatedImage = (UIImage<SDAnimatedImage> *)image;
        self.totalFrameCount = animatedImageFrameCount;
        // Get the current frame and loop count.
        self.totalLoopCount = self.animatedImage.animatedImageLoopCount;
        // Get the scale
        self.animatedImageScale = image.scale;
        if (!self.isProgressive) {
            self.currentFrame = image;
            LOCKBLOCK({
                self.frameBuffer[@(self.currentFrameIndex)] = self.currentFrame;
            });
        }
        
        // Ensure disabled highlighting; it's not supported (see `-setHighlighted:`).
        super.highlighted = NO;
        // UIImageView seems to bypass some accessors when calculating its intrinsic content size, so this ensures its intrinsic content size comes from the animated image.
        [self invalidateIntrinsicContentSize];
        
        // Calculate max buffer size
        [self calculateMaxBufferCount];
        // Update should animate
        [self updateShouldAnimate];
        if (self.shouldAnimate) {
            [self startAnimating];
        }
        
        [self.layer setNeedsDisplay];
#if SD_MAC
        [self.layer displayIfNeeded]; // macOS's imageViewLayer is not equal to self.layer. But `[super setImage:]` will impliedly mark it needsDisplay. We call `[self.layer displayIfNeeded]` to immediately refresh the imageViewLayer to avoid flashing
#endif
    }
}

- (void)setAnimationRepeatCount:(NSInteger)animationRepeatCount
{
#if SD_MAC
    _animationRepeatCount = animationRepeatCount;
#else
    [super setAnimationRepeatCount:animationRepeatCount];
#endif
}

#if SD_UIKIT
- (void)setRunLoopMode:(NSString *)runLoopMode
{
    if (![@[NSDefaultRunLoopMode, NSRunLoopCommonModes] containsObject:runLoopMode]) {
        NSAssert(NO, @"Invalid run loop mode: %@", runLoopMode);
        _runLoopMode = [[self class] defaultRunLoopMode];
    } else {
        _runLoopMode = runLoopMode;
    }
}
#endif

#pragma mark - Private
- (NSOperationQueue *)fetchQueue
{
    if (!_fetchQueue) {
        _fetchQueue = [[NSOperationQueue alloc] init];
        _fetchQueue.maxConcurrentOperationCount = 1;
    }
    return _fetchQueue;
}

- (NSMutableDictionary<NSNumber *,UIImage *> *)frameBuffer
{
    if (!_frameBuffer) {
        _frameBuffer = [NSMutableDictionary dictionary];
    }
    return _frameBuffer;
}

#if SD_MAC
- (CVDisplayLinkRef)displayLink
{
    if (!_displayLink) {
        CGDirectDisplayID displayID = CGMainDisplayID();
        CVReturn error = CVDisplayLinkCreateWithCGDisplay(displayID, &_displayLink);
        if (error) {
            return NULL;
        }
        CVDisplayLinkSetOutputCallback(_displayLink, renderCallback, (__bridge void *)self);
    }
    return _displayLink;
}
#else
- (CADisplayLink *)displayLink
{
    if (!_displayLink) {
        // It is important to note the use of a weak proxy here to avoid a retain cycle. `-displayLinkWithTarget:selector:`
        // will retain its target until it is invalidated. We use a weak proxy so that the image view will get deallocated
        // independent of the display link's lifetime. Upon image view deallocation, we invalidate the display
        // link which will lead to the deallocation of both the display link and the weak proxy.
        SDWeakProxy *weakProxy = [SDWeakProxy proxyWithTarget:self];
        _displayLink = [CADisplayLink displayLinkWithTarget:weakProxy selector:@selector(displayDidRefresh:)];
        [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:self.runLoopMode];
    }
    return _displayLink;
}
#endif

#if SD_MAC
- (CALayer *)imageViewLayer {
    NSView *imageView = objc_getAssociatedObject(self, NSSelectorFromString(@"_imageView"));
    return imageView.layer;
}
#endif

#pragma mark - Life Cycle

- (void)dealloc
{
    // Removes the display link from all run loop modes.
#if SD_MAC
    if (_displayLink) {
        CVDisplayLinkRelease(_displayLink);
        _displayLink = NULL;
    }
#else
    [_displayLink invalidate];
    _displayLink = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
#endif
}

- (void)didReceiveMemoryWarning:(NSNotification *)notification {
    [_fetchQueue cancelAllOperations];
    [_fetchQueue addOperationWithBlock:^{
        NSNumber *currentFrameIndex = @(self.currentFrameIndex);
        LOCKBLOCK({
            NSArray *keys = self.frameBuffer.allKeys;
            // only keep the next frame for later rendering
            for (NSNumber * key in keys) {
                if (![key isEqualToNumber:currentFrameIndex]) {
                    [self.frameBuffer removeObjectForKey:key];
                }
            }
        });
    }];
}

#pragma mark - UIView Method Overrides
#pragma mark Observing View-Related Changes

#if SD_MAC
- (void)viewDidMoveToSuperview
#else
- (void)didMoveToSuperview
#endif
{
#if SD_MAC
    [super viewDidMoveToSuperview];
#else
    [super didMoveToSuperview];
#endif
    
    [self updateShouldAnimate];
    if (self.shouldAnimate) {
        [self startAnimating];
    } else {
        [self stopAnimating];
    }
}

#if SD_MAC
- (void)viewDidMoveToWindow
#else
- (void)didMoveToWindow
#endif
{
#if SD_MAC
    [super viewDidMoveToWindow];
#else
    [super didMoveToWindow];
#endif
    
    [self updateShouldAnimate];
    if (self.shouldAnimate) {
        [self startAnimating];
    } else {
        [self stopAnimating];
    }
}

#if SD_MAC
- (void)setAlphaValue:(CGFloat)alphaValue
#else
- (void)setAlpha:(CGFloat)alpha
#endif
{
#if SD_MAC
    [super setAlphaValue:alphaValue];
#else
    [super setAlpha:alpha];
#endif
    
    [self updateShouldAnimate];
    if (self.shouldAnimate) {
        [self startAnimating];
    } else {
        [self stopAnimating];
    }
}

- (void)setHidden:(BOOL)hidden
{
    [super setHidden:hidden];
    
    [self updateShouldAnimate];
    if (self.shouldAnimate) {
        [self startAnimating];
    } else {
        [self stopAnimating];
    }
}

#pragma mark Auto Layout

- (CGSize)intrinsicContentSize
{
    // Default to let UIImageView handle the sizing of its image, and anything else it might consider.
    CGSize intrinsicContentSize = [super intrinsicContentSize];
    
    // If we have have an animated image, use its image size.
    // UIImageView's intrinsic content size seems to be the size of its image. The obvious approach, simply calling `-invalidateIntrinsicContentSize` when setting an animated image, results in UIImageView steadfastly returning `{UIViewNoIntrinsicMetric, UIViewNoIntrinsicMetric}` for its intrinsicContentSize.
    // (Perhaps UIImageView bypasses its `-image` getter in its implementation of `-intrinsicContentSize`, as `-image` is not called after calling `-invalidateIntrinsicContentSize`.)
    if (self.animatedImage) {
        intrinsicContentSize = self.image.size;
    }
    
    return intrinsicContentSize;
}

#pragma mark - UIImageView Method Overrides
#pragma mark Image Data

- (void)startAnimating
{
    if (self.animatedImage) {
#if SD_MAC
        CVDisplayLinkStart(self.displayLink);
#else
        self.displayLink.paused = NO;
#endif
    } else {
#if SD_UIKIT
        [super startAnimating];
#endif
    }
}

- (void)stopAnimating
{
    if (self.animatedImage) {
#if SD_MAC
        CVDisplayLinkStop(_displayLink);
#else
        _displayLink.paused = YES;
#endif
    } else {
#if SD_UIKIT
        [super stopAnimating];
#endif
    }
}

- (BOOL)isAnimating
{
    BOOL isAnimating = NO;
    if (self.animatedImage) {
#if SD_MAC
        isAnimating = CVDisplayLinkIsRunning(self.displayLink);
#else
        isAnimating = !self.displayLink.isPaused;
#endif
    } else {
#if SD_UIKIT
        isAnimating = [super isAnimating];
#endif
    }
    return isAnimating;
}

#if SD_MAC
- (void)setAnimates:(BOOL)animates
{
    [super setAnimates:animates];
    if (animates) {
        [self startAnimating];
    } else {
        [self stopAnimating];
    }
}
#endif

#pragma mark Highlighted Image Unsupport

- (void)setHighlighted:(BOOL)highlighted
{
    // Highlighted image is unsupported for animated images, but implementing it breaks the image view when embedded in a UICollectionViewCell.
    if (!self.animatedImage) {
        [super setHighlighted:highlighted];
    }
}


#pragma mark - Private Methods
#pragma mark Animation

// Don't repeatedly check our window & superview in `-displayDidRefresh:` for performance reasons.
// Just update our cached value whenever the animated image or visibility (window, superview, hidden, alpha) is changed.
- (void)updateShouldAnimate
{
#if SD_MAC
    BOOL isVisible = self.window && self.superview && ![self isHidden] && self.alphaValue > 0.0 && self.animates;
#else
    BOOL isVisible = self.window && self.superview && ![self isHidden] && self.alpha > 0.0;
#endif
    self.shouldAnimate = self.animatedImage && self.totalFrameCount > 1 && isVisible;
}

// Update progressive status only after `setImage:` call.
- (void)updateIsProgressiveWithImage:(UIImage *)image
{
    self.isProgressive = NO;
    if (!self.shouldIncrementalLoad) {
        // Early return
        return;
    }
    if ([image conformsToProtocol:@protocol(SDAnimatedImage)] && image.sd_isIncremental) {
        UIImage *previousImage = self.image;
        if ([previousImage conformsToProtocol:@protocol(SDAnimatedImage)] && previousImage.sd_isIncremental) {
            NSData *previousData = [((UIImage<SDAnimatedImage> *)previousImage) animatedImageData];
            NSData *currentData = [((UIImage<SDAnimatedImage> *)image) animatedImageData];
            // Check whether to use progressive rendering or not
            if (!previousData || !currentData) {
                // Early return
                return;
            }
            
            // Warning: normally the `previousData` is same instance as `currentData` because our `SDAnimatedImage` class share the same `coder` instance internally. But there may be a race condition, that later retrived `currentData` is already been updated and it's not the same instance as `previousData`.
            // And for protocol extensible design, we should not assume `SDAnimatedImage` protocol implementations always share same instance. So both of two reasons, we need that `rangeOfData` check.
            if ([currentData isEqualToData:previousData]) {
                // If current data is the same data (or instance) as previous data
                self.isProgressive = YES;
            } else if (currentData.length > previousData.length) {
                // If current data is appended by previous data, use `NSDataSearchAnchored`
                NSRange range = [currentData rangeOfData:previousData options:NSDataSearchAnchored range:NSMakeRange(0, previousData.length)];
                if (range.location == 0) {
                    // Contains hole previous data and they start with the same beginning
                    self.isProgressive = YES;
                }
            }
        } else {
            // Previous image is not progressive, so start progressive rendering
            self.isProgressive = YES;
        }
    }
}

#if SD_MAC
- (void)displayDidRefresh:(CVDisplayLinkRef)displayLink duration:(NSTimeInterval)duration
#else
- (void)displayDidRefresh:(CADisplayLink *)displayLink
#endif
{
    // If for some reason a wild call makes it through when we shouldn't be animating, bail.
    // Early return!
    if (!self.shouldAnimate) {
        return;
    }
    
#if SD_UIKIT
    NSTimeInterval duration = displayLink.duration * displayLink.frameInterval;
#endif
    NSUInteger totalFrameCount = self.totalFrameCount;
    NSUInteger currentFrameIndex = self.currentFrameIndex;
    NSUInteger nextFrameIndex = (currentFrameIndex + 1) % totalFrameCount;
    
    // Check if we have the frame buffer firstly to improve performance
    if (!self.bufferMiss) {
        // Then check if timestamp is reached
        self.currentTime += duration;
        NSTimeInterval currentDuration = [self.animatedImage animatedImageDurationAtIndex:currentFrameIndex];
        if (self.currentTime < currentDuration) {
            // Current frame timestamp not reached, return
            return;
        }
        self.currentTime -= currentDuration;
        NSTimeInterval nextDuration = [self.animatedImage animatedImageDurationAtIndex:nextFrameIndex];
        if (self.currentTime > nextDuration) {
            // Do not skip frame
            self.currentTime = nextDuration;
        }
    }
    
    // Update the current frame
    UIImage *currentFrame;
    LOCKBLOCK({
        currentFrame = self.frameBuffer[@(currentFrameIndex)];
    });
    BOOL bufferFull = NO;
    if (currentFrame) {
        LOCKBLOCK({
            // Remove the frame buffer if need
            if (self.frameBuffer.count > self.maxBufferCount) {
                self.frameBuffer[@(currentFrameIndex)] = nil;
            }
            // Check whether we can stop fetch
            if (self.frameBuffer.count == totalFrameCount) {
                bufferFull = YES;
            }
        });
        self.currentFrame = currentFrame;
        self.currentFrameIndex = nextFrameIndex;
        self.bufferMiss = NO;
        [self.layer setNeedsDisplay];
    } else {
        self.bufferMiss = YES;
    }
    
    // Update the loop count when last frame rendered
    if (nextFrameIndex == 0 && !self.bufferMiss) {
        // Progressive image reach the current last frame index. Keep the state and stop animating. Wait for later restart
        if (self.isProgressive) {
            // Recovery the current frame index and removed frame buffer (See above)
            self.currentFrameIndex = currentFrameIndex;
            LOCKBLOCK({
                self.frameBuffer[@(currentFrameIndex)] = self.currentFrame;
            });
            [self stopAnimating];
            return;
        }
        // Update the loop count
        self.currentLoopCount++;
        // if reached the max loop count, stop animating, 0 means loop indefinitely
        NSUInteger maxLoopCount = self.shouldCustomLoopCount ? self.animationRepeatCount : self.totalLoopCount;
        if (maxLoopCount != 0 && (self.currentLoopCount >= maxLoopCount)) {
            [self stopAnimating];
            return;
        }
    }
    
    // Check if we should prefetch next frame or current frame
    NSUInteger fetchFrameIndex;
    if (self.bufferMiss) {
        // When buffer miss, means the decode speed is slower than render speed, we fetch current miss frame
        fetchFrameIndex = currentFrameIndex;
    } else {
        // Or, most cases, the decode speed is faster than render speed, we fetch next frame
        fetchFrameIndex = nextFrameIndex;
    }
    
    UIImage *fetchFrame;
    LOCKBLOCK({
        fetchFrame = self.frameBuffer[@(fetchFrameIndex)];
    });
    
    if (!fetchFrame && !bufferFull && self.fetchQueue.operationCount == 0) {
        // Prefetch next frame in background queue
        UIImage<SDAnimatedImage> *animatedImage = self.animatedImage;
        NSOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
            UIImage *frame = [animatedImage animatedImageFrameAtIndex:fetchFrameIndex];
            LOCKBLOCK({
                self.frameBuffer[@(fetchFrameIndex)] = frame;
            });
        }];
        [self.fetchQueue addOperation:operation];
    }
}

+ (NSString *)defaultRunLoopMode
{
    // Key off `activeProcessorCount` (as opposed to `processorCount`) since the system could shut down cores in certain situations.
    return [NSProcessInfo processInfo].activeProcessorCount > 1 ? NSRunLoopCommonModes : NSDefaultRunLoopMode;
}


#pragma mark Providing the Layer's Content
#pragma mark - CALayerDelegate

- (void)displayLayer:(CALayer *)layer
{
    if (_currentFrame) {
        layer.contentsScale = self.animatedImageScale;
        layer.contents = (__bridge id)_currentFrame.CGImage;
    }
}

#if SD_MAC
- (void)updateLayer
{
    if (_currentFrame) {
        [self displayLayer:self.imageViewLayer];
    } else {
        [super updateLayer];
    }
}
#endif


#pragma mark - Util
- (void)calculateMaxBufferCount {
    NSUInteger bytes = CGImageGetBytesPerRow(self.currentFrame.CGImage) * CGImageGetHeight(self.currentFrame.CGImage);
    if (bytes == 0) bytes = 1024;
    
    NSUInteger max = 0;
    if (self.maxBufferSize > 0) {
        max = self.maxBufferSize;
    } else {
        // Calculate based on current memory, these factors are by experience
        NSUInteger total = SDDeviceTotalMemory();
        NSUInteger free = SDDeviceFreeMemory();
        max = MIN(total * 0.2, free * 0.6);
    }
    
    NSUInteger maxBufferCount = (double)max / (double)bytes;
    if (!maxBufferCount) {
        // At least 1 frame
        maxBufferCount = 1;
    }
    
    self.maxBufferCount = maxBufferCount;
}

@end

#if SD_MAC
static CVReturn renderCallback(CVDisplayLinkRef displayLink, const CVTimeStamp *inNow, const CVTimeStamp *inOutputTime, CVOptionFlags flagsIn, CVOptionFlags *flagsOut, void *displayLinkContext) {
    // Calculate refresh duration
    NSTimeInterval duration = (double)inOutputTime->videoRefreshPeriod / ((double)inOutputTime->videoTimeScale * inOutputTime->rateScalar);
    // CVDisplayLink callback is not on main queue
    dispatch_async(dispatch_get_main_queue(), ^{
        [(__bridge SDAnimatedImageView *)displayLinkContext displayDidRefresh:displayLink duration:duration];
    });
    return kCVReturnSuccess;
}
#endif

#endif
