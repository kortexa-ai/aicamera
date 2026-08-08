#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static _Atomic(UInt32) runningNotifications = 0;
static _Atomic(UInt32) configurationRequestCount = 0;
static _Atomic(UInt64) configurationActions[4];

static OSStatus hostPropertiesChanged(
    AudioServerPlugInHostRef host,
    AudioObjectID objectID,
    UInt32 count,
    const AudioObjectPropertyAddress *addresses
) {
    (void)host;
    if (objectID == 3 && addresses != NULL) {
        for (UInt32 index = 0; index < count; ++index) {
            if (addresses[index].mSelector == kAudioDevicePropertyDeviceIsRunning) {
                atomic_fetch_add_explicit(&runningNotifications, 1, memory_order_relaxed);
            }
        }
    }
    return noErr;
}

static OSStatus hostCopyFromStorage(
    AudioServerPlugInHostRef host,
    CFStringRef key,
    CFPropertyListRef *outData
) {
    (void)host; (void)key;
    *outData = NULL;
    return noErr;
}

static OSStatus hostWriteToStorage(
    AudioServerPlugInHostRef host,
    CFStringRef key,
    CFPropertyListRef data
) {
    (void)host; (void)key; (void)data;
    return noErr;
}

static OSStatus hostDeleteFromStorage(AudioServerPlugInHostRef host, CFStringRef key) {
    (void)host; (void)key;
    return noErr;
}

static OSStatus hostRequestConfigurationChange(
    AudioServerPlugInHostRef host,
    AudioObjectID deviceID,
    UInt64 action,
    void *info
) {
    (void)host; (void)info;
    if (deviceID != 3) return kAudioHardwareBadObjectError;
    UInt32 index = atomic_load_explicit(&configurationRequestCount, memory_order_relaxed);
    if (index >= 4) return kAudioHardwareIllegalOperationError;
    atomic_store_explicit(&configurationActions[index], action, memory_order_relaxed);
    atomic_store_explicit(&configurationRequestCount, index + 1, memory_order_release);
    return noErr;
}

static const AudioServerPlugInHostInterface testHost = {
    hostPropertiesChanged,
    hostCopyFromStorage,
    hostWriteToStorage,
    hostDeleteFromStorage,
    hostRequestConfigurationChange,
};

static OSStatus getProperty(
    AudioServerPlugInDriverRef driver,
    AudioObjectID objectID,
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope,
    UInt32 bufferSize,
    UInt32 *outSize,
    void *buffer
) {
    AudioObjectPropertyAddress address = {
        selector, scope, kAudioObjectPropertyElementMain
    };
    if (!(*driver)->HasProperty(driver, objectID, 0, &address)) return kAudioHardwareUnknownPropertyError;
    return (*driver)->GetPropertyData(
        driver, objectID, 0, &address, 0, NULL, bufferSize, outSize, buffer
    );
}

static int checkListProperty(
    AudioServerPlugInDriverRef driver,
    AudioObjectID objectID,
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope,
    const AudioObjectID *expected,
    UInt32 expectedCount
) {
    AudioObjectPropertyAddress address = {
        selector, scope, kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (!(*driver)->HasProperty(driver, objectID, 0, &address)) return 0;
    if ((*driver)->GetPropertyDataSize(driver, objectID, 0, &address, 0, NULL, &size) != noErr) return 0;
    if (size != expectedCount * sizeof(AudioObjectID)) return 0;
    AudioObjectID values[16];
    memset(values, 0xA5, sizeof(values));
    UInt32 written = 0;
    if ((*driver)->GetPropertyData(
            driver, objectID, 0, &address, 0, NULL, size, &written, values
        ) != noErr || written != size) return 0;
    return size == 0 || memcmp(values, expected, size) == 0;
}

static int checkQualifiedOwnedObjects(
    AudioServerPlugInDriverRef driver,
    AudioObjectID objectID,
    AudioClassID qualifier,
    const AudioObjectID *expected,
    UInt32 expectedCount
) {
    AudioObjectPropertyAddress address = {
        kAudioObjectPropertyOwnedObjects,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if ((*driver)->GetPropertyDataSize(
            driver, objectID, 0, &address, sizeof(qualifier), &qualifier, &size
        ) != noErr || size != expectedCount * sizeof(AudioObjectID)) return 0;
    AudioObjectID values[4];
    memset(values, 0xA5, sizeof(values));
    UInt32 written = 0;
    if ((*driver)->GetPropertyData(
            driver, objectID, 0, &address, sizeof(qualifier), &qualifier,
            size, &written, values
        ) != noErr || written != size) return 0;
    return size == 0 || memcmp(values, expected, size) == 0;
}

static int waitForConfigurationRequests(UInt32 count) {
    for (UInt32 attempt = 0; attempt < 1000; ++attempt) {
        if (atomic_load_explicit(&configurationRequestCount, memory_order_acquire) >= count) return 1;
        usleep(1000);
    }
    return 0;
}

static int validateCoalescedSampleRate(AudioServerPlugInDriverRef driver) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    Float64 rate = 44100.0;
    if ((*driver)->SetPropertyData(driver, 3, 0, &address, 0, NULL, sizeof(rate), &rate) != noErr ||
        !waitForConfigurationRequests(1) ||
        atomic_load_explicit(&configurationActions[0], memory_order_relaxed) != 44100) return 0;

    rate = 48000.0;
    if ((*driver)->SetPropertyData(driver, 3, 0, &address, 0, NULL, sizeof(rate), &rate) != noErr) return 0;
    usleep(20000);
    if (atomic_load_explicit(&configurationRequestCount, memory_order_acquire) != 1) return 0;
    if ((*driver)->PerformDeviceConfigurationChange(driver, 3, 44100, NULL) != noErr ||
        !waitForConfigurationRequests(2) ||
        atomic_load_explicit(&configurationActions[1], memory_order_relaxed) != 48000) return 0;
    if ((*driver)->PerformDeviceConfigurationChange(driver, 3, 48000, NULL) != noErr) return 0;

    UInt32 written = 0;
    rate = 0;
    return getProperty(driver, 3, kAudioDevicePropertyNominalSampleRate,
                       kAudioObjectPropertyScopeGlobal, sizeof(rate), &written, &rate) == noErr &&
        written == sizeof(rate) && rate == 48000.0;
}

static int validatePropertyGraph(AudioServerPlugInDriverRef driver) {
    const AudioObjectID pluginObjects[] = {2, 3};
    const AudioObjectID deviceObjects[] = {4, 8};
    const AudioObjectID streams[] = {4, 8};
    if (!checkListProperty(driver, kAudioObjectPlugInObject, kAudioObjectPropertyOwnedObjects,
                           kAudioObjectPropertyScopeGlobal, pluginObjects, 2)) return 1;
    if (!checkListProperty(driver, 3, kAudioObjectPropertyOwnedObjects,
                           kAudioObjectPropertyScopeGlobal, deviceObjects, 2)) return 2;
    if (!checkListProperty(driver, 3, kAudioDevicePropertyStreams,
                           kAudioObjectPropertyScopeGlobal, streams, 2)) return 3;
    if (!checkListProperty(driver, 3, kAudioObjectPropertyControlList,
                           kAudioObjectPropertyScopeGlobal, NULL, 0)) return 4;

    const AudioObjectID inputStream[] = {4};
    const AudioObjectID outputStream[] = {8};
    if (!checkListProperty(driver, 3, kAudioObjectPropertyOwnedObjects,
                           kAudioObjectPropertyScopeInput, inputStream, 1)) return 18;
    if (!checkListProperty(driver, 3, kAudioObjectPropertyOwnedObjects,
                           kAudioObjectPropertyScopeOutput, outputStream, 1)) return 19;
    if (!checkListProperty(driver, 3, kAudioObjectPropertyOwnedObjects,
                           kAudioObjectPropertyScopePlayThrough, NULL, 0)) return 20;
    if (!checkListProperty(driver, 3, kAudioDevicePropertyStreams,
                           kAudioObjectPropertyScopeInput, inputStream, 1)) return 21;
    if (!checkListProperty(driver, 3, kAudioDevicePropertyStreams,
                           kAudioObjectPropertyScopeOutput, outputStream, 1)) return 22;
    if (!checkListProperty(driver, 3, kAudioDevicePropertyStreams,
                           kAudioObjectPropertyScopePlayThrough, NULL, 0)) return 23;

    const AudioObjectID boxOnly[] = {2};
    const AudioObjectID deviceOnly[] = {3};
    if (!checkQualifiedOwnedObjects(driver, 1, kAudioBoxClassID, boxOnly, 1)) return 13;
    if (!checkQualifiedOwnedObjects(driver, 1, kAudioDeviceClassID, deviceOnly, 1)) return 14;
    if (!checkQualifiedOwnedObjects(driver, 3, kAudioStreamClassID, streams, 2)) return 15;
    if (!checkQualifiedOwnedObjects(driver, 3, kAudioControlClassID, NULL, 0)) return 16;

    if (!checkQualifiedOwnedObjects(driver, 1, kAudioObjectClassID, pluginObjects, 2)) return 24;
    if (!checkQualifiedOwnedObjects(driver, 3, kAudioObjectClassID, streams, 2)) return 25;
    if (!checkQualifiedOwnedObjects(driver, 3, kAudioDeviceClassID, NULL, 0)) return 26;

    AudioClassID combinedQualifiers[] = {kAudioBoxClassID, kAudioDeviceClassID};
    AudioObjectPropertyAddress combinedAddress = {
        kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    AudioObjectID combinedObjects[2] = {0, 0};
    UInt32 combinedSize = 0, combinedWritten = 0;
    if ((*driver)->GetPropertyDataSize(driver, 1, 0, &combinedAddress,
            sizeof(combinedQualifiers), combinedQualifiers, &combinedSize) != noErr ||
        combinedSize != sizeof(combinedObjects) ||
        (*driver)->GetPropertyData(driver, 1, 0, &combinedAddress,
            sizeof(combinedQualifiers), combinedQualifiers, sizeof(combinedObjects),
            &combinedWritten, combinedObjects) != noErr || combinedWritten != sizeof(combinedObjects) ||
        memcmp(combinedObjects, pluginObjects, sizeof(combinedObjects)) != 0) return 28;

    AudioObjectPropertyAddress ownedAddress = {
        kAudioObjectPropertyOwnedObjects,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt8 malformedQualifier = 0;
    UInt32 malformedSize = 0;
    if ((*driver)->GetPropertyDataSize(
            driver, 3, 0, &ownedAddress, 1, &malformedQualifier, &malformedSize
        ) == noErr) return 17;

    AudioObjectPropertyAddress invalidAddresses[] = {
        {kAudioObjectPropertyManufacturer, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain},
        {kAudioObjectPropertyControlList, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain},
        {kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain},
        {kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain},
    };
    AudioObjectID invalidObjects[] = {1, 3, 3, 4};
    for (size_t index = 0; index < sizeof(invalidObjects) / sizeof(invalidObjects[0]); ++index) {
        UInt32 invalidSize = 0;
        if ((*driver)->HasProperty(driver, invalidObjects[index], 0, &invalidAddresses[index]) ||
            (*driver)->GetPropertyDataSize(driver, invalidObjects[index], 0, &invalidAddresses[index],
                                           0, NULL, &invalidSize) == noErr) return 27;
    }

    AudioObjectPropertyAddress uidAddress = {
        kAudioBoxPropertyBoxUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    UInt32 uidSize = 0;
    if ((*driver)->GetPropertyDataSize(driver, 2, 0, &uidAddress, 0, NULL, &uidSize) != noErr ||
        uidSize != sizeof(CFStringRef)) return 5;
    CFStringRef uid = NULL;
    UInt32 written = 0;
    if (getProperty(driver, 2, kAudioBoxPropertyBoxUID, kAudioObjectPropertyScopeGlobal,
                    sizeof(uid), &written, &uid) != noErr || written != sizeof(uid) || uid == NULL) return 6;

    // An undersized request must fail without writing or leaving the state mutex locked.
    UInt64 canary = 0x1122334455667788ULL;
    written = 0xA5A5A5A5;
    if (getProperty(driver, kAudioObjectPlugInObject, kAudioPlugInPropertyResourceBundle,
                    kAudioObjectPropertyScopeGlobal, sizeof(UInt32), &written, &canary) == noErr ||
        canary != 0x1122334455667788ULL) return 7;
    AudioObjectID device = 0;
    written = 0;
    if (getProperty(driver, 2, kAudioBoxPropertyDeviceList, kAudioObjectPropertyScopeGlobal,
                    0, &written, &device) == noErr) return 8;
    if (getProperty(driver, 2, kAudioBoxPropertyDeviceList, kAudioObjectPropertyScopeGlobal,
                    sizeof(device), &written, &device) != noErr ||
        written != sizeof(device) || device != 3) return 9;

    struct GraphExpectation {
        AudioObjectID objectID;
        AudioClassID classID;
        AudioClassID baseClassID;
        AudioObjectID ownerID;
    } graph[] = {
        {1, kAudioPlugInClassID, kAudioObjectClassID, kAudioObjectUnknown},
        {2, kAudioBoxClassID, kAudioObjectClassID, 1},
        {3, kAudioDeviceClassID, kAudioObjectClassID, 1},
        {4, kAudioStreamClassID, kAudioObjectClassID, 3},
        {8, kAudioStreamClassID, kAudioObjectClassID, 3},
    };
    for (size_t index = 0; index < sizeof(graph) / sizeof(graph[0]); ++index) {
        AudioClassID classID = 0, baseClassID = 0;
        AudioObjectID ownerID = kAudioObjectUnknown;
        written = 0;
        if (getProperty(driver, graph[index].objectID, kAudioObjectPropertyClass,
                        kAudioObjectPropertyScopeGlobal, sizeof(classID), &written, &classID) != noErr ||
            written != sizeof(classID) || classID != graph[index].classID) return 10;
        if (getProperty(driver, graph[index].objectID, kAudioObjectPropertyBaseClass,
                        kAudioObjectPropertyScopeGlobal, sizeof(baseClassID), &written, &baseClassID) != noErr ||
            written != sizeof(baseClassID) || baseClassID != graph[index].baseClassID) return 11;
        if (getProperty(driver, graph[index].objectID, kAudioObjectPropertyOwner,
                        kAudioObjectPropertyScopeGlobal, sizeof(ownerID), &written, &ownerID) != noErr ||
            written != sizeof(ownerID) || ownerID != graph[index].ownerID) return 12;
    }

    for (AudioObjectID streamID = 4; streamID <= 8; streamID += 4) {
        AudioStreamBasicDescription format;
        memset(&format, 0xA5, sizeof(format));
        written = 0;
        if (getProperty(driver, streamID, kAudioStreamPropertyVirtualFormat,
                        kAudioObjectPropertyScopeGlobal, sizeof(format), &written, &format) != noErr ||
            written != sizeof(format) || format.mReserved != 0) return 11;
        AudioStreamRangedDescription available[2];
        memset(available, 0xA5, sizeof(available));
        written = 0;
        if (getProperty(driver, streamID, kAudioStreamPropertyAvailableVirtualFormats,
                        kAudioObjectPropertyScopeGlobal, sizeof(available), &written, available) != noErr ||
            written != sizeof(available) || available[0].mFormat.mReserved != 0 ||
            available[1].mFormat.mReserved != 0) return 12;
    }
    return 0;
}

static AudioServerPlugInDriverRef loadDriver(const char *path) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        NULL, (const UInt8 *)path, (CFIndex)strlen(path), true
    );
    if (url == NULL) return NULL;
    CFPlugInRef plugin = CFPlugInCreate(NULL, url);
    CFRelease(url);
    if (plugin == NULL) return NULL;
    CFArrayRef identifiers = CFPlugInFindFactoriesForPlugInTypeInPlugIn(
        kAudioServerPlugInTypeUUID, plugin
    );
    if (identifiers == NULL || CFArrayGetCount(identifiers) == 0) {
        if (identifiers != NULL) CFRelease(identifiers);
        CFRelease(plugin);
        return NULL;
    }
    CFUUIDRef factory = (CFUUIDRef)CFArrayGetValueAtIndex(identifiers, 0);
    AudioServerPlugInDriverRef driver = (AudioServerPlugInDriverRef)
        CFPlugInInstanceCreate(NULL, factory, kAudioServerPlugInTypeUUID);
    // Keep plug-in code resident until this process exits.
    CFRetain(plugin);
    CFRelease(identifiers);
    CFRelease(plugin);
    return driver;
}

static int equal(const float *left, const float *right, size_t count) {
    for (size_t index = 0; index < count; ++index) {
        if (left[index] != right[index]) return 0;
    }
    return 1;
}

static void setTime(AudioTimeStamp *timestamp, double frame) {
    memset(timestamp, 0, sizeof(*timestamp));
    timestamp->mSampleTime = frame;
    timestamp->mFlags = kAudioTimeStampSampleTimeValid;
}

static int writeFrames(
    AudioServerPlugInDriverRef driver,
    AudioServerPlugInIOCycleInfo *cycle,
    double frame,
    UInt32 count,
    float *samples
) {
    setTime(&cycle->mOutputTime, frame);
    return (*driver)->DoIOOperation(
        driver, 3, 8, 1, kAudioServerPlugInIOOperationWriteMix,
        count, cycle, samples, NULL
    );
}

static int readFrames(
    AudioServerPlugInDriverRef driver,
    AudioServerPlugInIOCycleInfo *cycle,
    UInt32 clientID,
    double frame,
    UInt32 count,
    float *samples
) {
    setTime(&cycle->mInputTime, frame);
    return (*driver)->DoIOOperation(
        driver, 3, 4, clientID, kAudioServerPlugInIOOperationReadInput,
        count, cycle, samples, NULL
    );
}

enum { stressFrames = 64, stressChunks = 20000 };
typedef struct {
    AudioServerPlugInDriverRef driver;
    _Atomic(UInt64) currentFrame;
    _Atomic(bool) done;
    _Atomic(bool) failed;
} StressContext;

static float stressSample(UInt64 frame, UInt32 channel) {
    return (float)(((frame % 1009) * 2) + channel + 1) / 4096.0f;
}

static void *stressWriter(void *rawContext) {
    StressContext *context = (StressContext *)rawContext;
    float samples[stressFrames * 2];
    AudioServerPlugInIOCycleInfo cycle;
    memset(&cycle, 0, sizeof(cycle));
    for (UInt64 chunk = 0; chunk < stressChunks; ++chunk) {
        UInt64 frame = chunk * stressFrames;
        for (UInt32 offset = 0; offset < stressFrames; ++offset) {
            samples[offset * 2] = stressSample(frame + offset, 0);
            samples[(offset * 2) + 1] = stressSample(frame + offset, 1);
        }
        if (writeFrames(context->driver, &cycle, (double)frame, stressFrames, samples) != noErr) {
            atomic_store_explicit(&context->failed, true, memory_order_release);
            break;
        }
        atomic_store_explicit(&context->currentFrame, frame, memory_order_release);
    }
    atomic_store_explicit(&context->done, true, memory_order_release);
    return NULL;
}

static void *stressReader(void *rawContext) {
    StressContext *context = (StressContext *)rawContext;
    float samples[stressFrames * 2];
    AudioServerPlugInIOCycleInfo cycle;
    memset(&cycle, 0, sizeof(cycle));
    UInt32 readsAfterDone = 0;
    while (!atomic_load_explicit(&context->done, memory_order_acquire) || readsAfterDone++ < 100) {
        UInt64 frame = atomic_load_explicit(&context->currentFrame, memory_order_acquire);
        if (frame == UINT64_MAX) continue;
        memset(samples, 0xA5, sizeof(samples));
        if (readFrames(context->driver, &cycle, 2, (double)frame, stressFrames, samples) != noErr) {
            atomic_store_explicit(&context->failed, true, memory_order_release);
            break;
        }
        for (UInt32 offset = 0; offset < stressFrames; ++offset) {
            float left = samples[offset * 2];
            float right = samples[(offset * 2) + 1];
            bool silent = left == 0.0f && right == 0.0f;
            bool complete = left == stressSample(frame + offset, 0) &&
                right == stressSample(frame + offset, 1);
            if (!silent && !complete) {
                atomic_store_explicit(&context->failed, true, memory_order_release);
                return NULL;
            }
        }
    }
    return NULL;
}

static int runConcurrentRingStress(AudioServerPlugInDriverRef driver) {
    StressContext context = {
        .driver = driver,
        .currentFrame = UINT64_MAX,
        .done = false,
        .failed = false,
    };
    pthread_t writer, reader;
    if (pthread_create(&writer, NULL, stressWriter, &context) != 0) return 0;
    if (pthread_create(&reader, NULL, stressReader, &context) != 0) {
        pthread_join(writer, NULL);
        return 0;
    }
    pthread_join(writer, NULL);
    pthread_join(reader, NULL);
    return !atomic_load_explicit(&context.failed, memory_order_acquire);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s /path/to/AICameraAudioDriver.driver\n", argv[0]);
        return 64;
    }
    AudioServerPlugInDriverRef driver = loadDriver(argv[1]);
    if (driver == NULL) return 1;

    CFUUIDRef unsupportedUUID = CFUUIDCreate(NULL);
    CFUUIDBytes unsupportedBytes = CFUUIDGetUUIDBytes(unsupportedUUID);
    CFRelease(unsupportedUUID);
    void *unsupportedInterface = (void *)(uintptr_t)0x12345678;
    if ((*driver)->QueryInterface(driver, unsupportedBytes, &unsupportedInterface) == 0 ||
        unsupportedInterface != NULL) return 2;

    if ((*driver)->Initialize(driver, &testHost) != noErr) return 3;
    int propertyFailure = validatePropertyGraph(driver);
    if (propertyFailure != 0) {
        fprintf(stderr, "HAL property graph check failed: %d\n", propertyFailure);
        return 20 + propertyFailure;
    }
    if (!validateCoalescedSampleRate(driver)) return 60;
    AudioServerPlugInClientInfo client1 = {1, getpid(), true, CFSTR("ai.kortexa.aicamera.harness.one")};
    AudioServerPlugInClientInfo client2 = {2, getpid(), true, CFSTR("ai.kortexa.aicamera.harness.two")};
    if ((*driver)->AddDeviceClient(driver, 3, &client1) != noErr ||
        (*driver)->AddDeviceClient(driver, 3, &client2) != noErr) return 4;
    if ((*driver)->StartIO(driver, 3, 1) != noErr ||
        (*driver)->StartIO(driver, 3, 2) != noErr) return 5;
    UInt64 hostTime = 0, seed = 0;
    volatile uintptr_t zeroAddress = (uintptr_t)(argc - argc);
    Float64 *missingSampleTime = (Float64 *)zeroAddress;
    if ((*driver)->GetZeroTimeStamp(driver, 3, 1, missingSampleTime, &hostTime, &seed) == noErr) return 6;
    usleep(750000);
    Float64 sampleTime = 0;
    if ((*driver)->GetZeroTimeStamp(driver, 3, 1, &sampleTime, &hostTime, &seed) != noErr ||
        sampleTime < 32768.0 || hostTime == 0 || seed == 0) return 7;
    UInt64 initialSeed = seed;
    if (!runConcurrentRingStress(driver)) return 8;

    float written[16], read1[16], read2[16], zero[16] = {0};
    for (int index = 0; index < 16; ++index) written[index] = (float)(index + 1) / 16.0f;
    AudioServerPlugInIOCycleInfo cycle;
    memset(&cycle, 0, sizeof(cycle));

    struct {
        float samples[2];
        UInt64 canary;
    } tiny = {{1.0f, 1.0f}, 0x1122334455667788ULL};
    setTime(&cycle.mInputTime, 0);
    if ((*driver)->DoIOOperation(
            driver, 3, 4, 2, kAudioServerPlugInIOOperationReadInput,
            16385, &cycle, tiny.samples, NULL
        ) == noErr || tiny.canary != 0x1122334455667788ULL ||
        tiny.samples[0] != 1.0f || tiny.samples[1] != 1.0f) return 7;

    memset(read1, 1, sizeof(read1));
    if (readFrames(driver, &cycle, 1, NAN, 8, read1) == noErr || !equal(zero, read1, 16)) return 7;
    memset(read1, 1, sizeof(read1));
    if (readFrames(driver, &cycle, 1, 1.5, 8, read1) == noErr || !equal(zero, read1, 16)) return 8;
    memset(read1, 1, sizeof(read1));
    if (readFrames(driver, &cycle, 1, 18446744073709551616.0, 8, read1) == noErr || !equal(zero, read1, 16)) return 9;

    memset(read1, 1, sizeof(read1));
    if (readFrames(driver, &cycle, 1, 0, 8, read1) != 0 || !equal(zero, read1, 16)) return 2;
    if (writeFrames(driver, &cycle, 512, 8, written) != 0) return 3;
    memset(read1, 0, sizeof(read1));
    if (readFrames(driver, &cycle, 1, 512, 8, read1) != 0 || !equal(written, read1, 16)) return 4;
    memset(read2, 0, sizeof(read2));
    if (readFrames(driver, &cycle, 2, 512, 8, read2) != 0 || !equal(written, read2, 16)) return 5;

    // A timeline gap invalidates stale samples.
    if (writeFrames(driver, &cycle, 1000, 8, written) != 0) return 6;
    memset(read1, 1, sizeof(read1));
    if (readFrames(driver, &cycle, 1, 520, 8, read1) != 0 || !equal(zero, read1, 16)) return 7;

    // The frame-indexed ring must wrap without changing samples.
    if (writeFrames(driver, &cycle, 16380, 8, written) != 0) return 8;
    memset(read1, 0, sizeof(read1));
    if (readFrames(driver, &cycle, 1, 16380, 8, read1) != 0 || !equal(written, read1, 16)) return 9;

    if ((*driver)->StopIO(driver, 3, 1) != noErr) return 30;
    if ((*driver)->StopIO(driver, 3, 2) != noErr) return 31;
    if ((*driver)->StartIO(driver, 3, 1) != noErr) return 32;
    memset(read1, 1, sizeof(read1));
    if (readFrames(driver, &cycle, 1, 16380, 8, read1) != noErr || !equal(zero, read1, 16)) return 33;
    sampleTime = -1;
    if ((*driver)->GetZeroTimeStamp(driver, 3, 1, &sampleTime, &hostTime, &seed) != noErr ||
        sampleTime >= 16384.0 || seed == initialSeed) return 34;
    if ((*driver)->StopIO(driver, 3, 1) != noErr) return 35;
    if ((*driver)->RemoveDeviceClient(driver, 3, &client1) != noErr ||
        (*driver)->RemoveDeviceClient(driver, 3, &client2) != noErr) return 36;
    if (atomic_load_explicit(&runningNotifications, memory_order_relaxed) != 4) return 37;

    (*driver)->Release(driver);
    puts("HAL harness passed: graph, address/size errors, clock, multi-client loopback, concurrent wrap, and reset");
    return 0;
}
