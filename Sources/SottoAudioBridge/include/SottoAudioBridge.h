#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// AVFAudio can raise Objective-C exceptions even from APIs that return NSError.
/// Keep those exceptions inside Objective-C; Swift do/catch cannot contain them.
@interface SottoAudioBridge : NSObject
+ (nullable AVAudioFormat *)inputFormatForNode:(AVAudioNode *)node error:(NSError **)error;
+ (BOOL)installTapOnNode:(AVAudioNode *)node
                 format:(AVAudioFormat *)format
                  block:(AVAudioNodeTapBlock)block
                  error:(NSError **)error;
+ (BOOL)prepareEngine:(AVAudioEngine *)engine error:(NSError **)error;
+ (BOOL)startEngine:(AVAudioEngine *)engine error:(NSError **)error;
+ (BOOL)stopEngine:(AVAudioEngine *)engine removeInputTap:(BOOL)removeTap error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
