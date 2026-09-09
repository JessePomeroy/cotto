#import "SottoAudioBridge.h"
#include <math.h>

static NSError *SetupError(NSString *detail) {
    return [NSError errorWithDomain:@"local.sotto.audio-setup" code:1 userInfo:@{
        NSLocalizedDescriptionKey: @"The microphone’s audio format changed or could not be opened. Please try again.",
        NSDebugDescriptionErrorKey: detail
    }];
}

static NSError *ExceptionError(NSException *exception) {
    return SetupError(exception.reason ?: exception.name);
}

@implementation SottoAudioBridge
+ (AVAudioFormat *)inputFormatForNode:(AVAudioNode *)node error:(NSError **)error {
    @try {
        // The input scope is the hardware format. The output/client scope can
        // still describe a previous device (e.g. 24 kHz after switching to 48 kHz).
        AVAudioFormat *format = [node inputFormatForBus:0];
        if (!isfinite(format.sampleRate) || format.sampleRate <= 0 || format.channelCount == 0) {
            if (error) *error = SetupError(@"The input has no usable hardware format.");
            return nil;
        }
        return format;
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return nil;
    }
}

+ (BOOL)installTapOnNode:(AVAudioNode *)node format:(AVAudioFormat *)format
                  block:(AVAudioNodeTapBlock)block error:(NSError **)error {
    @try {
        AVAudioFormat *current = [self inputFormatForNode:node error:error];
        if (!current) return NO;
        if (![current isEqual:format]) {
            if (error) *error = SetupError(@"The hardware format changed before the tap was installed.");
            return NO;
        }
        // Never force the device's nominal rate or the Mac's default input.
        // The writer resamples this hardware-native PCM to 16 kHz separately.
        [node installTapOnBus:0 bufferSize:2048 format:format block:block];
        return YES;
    } @catch (NSException *exception) {
        // A driver can renegotiate after the check above. Discard this engine;
        // report a recoverable error instead of allowing SIGABRT to kill Sotto.
        if (error) *error = ExceptionError(exception);
        return NO;
    }
}

+ (BOOL)prepareEngine:(AVAudioEngine *)engine error:(NSError **)error {
    @try {
        [engine prepare];
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return NO;
    }
}

+ (BOOL)startEngine:(AVAudioEngine *)engine error:(NSError **)error {
    @try {
        return [engine startAndReturnError:error];
    } @catch (NSException *exception) {
        if (error) *error = ExceptionError(exception);
        return NO;
    }
}

+ (BOOL)stopEngine:(AVAudioEngine *)engine removeInputTap:(BOOL)removeTap error:(NSError **)error {
    NSError *failure = nil;
    @try {
        if (removeTap) [[engine inputNode] removeTapOnBus:0];
    } @catch (NSException *exception) {
        failure = ExceptionError(exception);
    }
    // Still stop our engine if detaching a partially configured tap failed.
    @try {
        [engine stop];
    } @catch (NSException *exception) {
        if (!failure) failure = ExceptionError(exception);
    }
    if (error) *error = failure;
    return failure == nil;
}
@end
