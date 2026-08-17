/*
Derived from Apple’s “Creating an Audio Server Driver Plug-in” NullAudio sample.
See docs/legal/APPLE_NULLAUDIO_LICENSE.txt for Apple’s copyright and license notice.

AI Camera Audio Driver publishes a two-channel Float32 duplex virtual audio device.
Audio written to its output stream is available from its input stream on the same
sample-time-indexed device timeline.
*/

/*==================================================================================================
	AICameraAudioDriver.c
==================================================================================================*/

//==================================================================================================
//	Includes
//==================================================================================================

//	System Includes
#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/syslog.h>

//==================================================================================================
#pragma mark -
#pragma mark Macros
//==================================================================================================

#if TARGET_RT_BIG_ENDIAN
	#define	FourCCToCString(the4CC)	{ ((char*)&the4CC)[0], ((char*)&the4CC)[1], ((char*)&the4CC)[2], ((char*)&the4CC)[3], 0 }
#else
	#define	FourCCToCString(the4CC)	{ ((char*)&the4CC)[3], ((char*)&the4CC)[2], ((char*)&the4CC)[1], ((char*)&the4CC)[0], 0 }
#endif

#if DEBUG

	#define	DebugMsg(...)		do { printf(__VA_ARGS__); printf("\n"); } while(0)

	#define	FailIf(inCondition, inHandler, inMessage)									\
			if(inCondition)																\
			{																			\
				DebugMsg(inMessage);													\
				goto inHandler;															\
			}

	#define	FailWithAction(inCondition, inAction, inHandler, inMessage)					\
			if(inCondition)																\
			{																			\
				DebugMsg(inMessage);													\
				{ inAction; }															\
				goto inHandler;															\
			}

#else

	#define	DebugMsg(...)		do { } while(0)

	#define	FailIf(inCondition, inHandler, inMessage)									\
			if(inCondition)																\
			{																			\
				goto inHandler;															\
			}

	#define	FailWithAction(inCondition, inAction, inHandler, inMessage)					\
			if(inCondition)																\
			{																			\
				{ inAction; }															\
				goto inHandler;															\
			}

#endif

//==================================================================================================
#pragma mark -
#pragma mark AICameraAudioDriver State
//==================================================================================================

//	This driver keeps the fixed object model from Apple’s NullAudio sample and adds a bounded
//	duplex loopback path. It has one input stream and one output stream, both with two channels of
//	interleaved 32-bit Float32 LPCM. It defaults to 48 kHz and also supports 44.1 kHz. WriteMix
//	buffers are stored by output sample time; ReadInput buffers retrieve the corresponding input
//	timeline range. Missing or stale ranges produce silence. The device does not publish optional
//	software controls; applications control gain and mute before writing to its output stream.


//	Declare the internal object ID numbers for all the objects this driver implements. Note that
//	this driver has a fixed set of objects that never grows or shrinks. If this were not the case,
//	the driver would need to have a means to dynamically allocate these IDs. It's important to
//	realize that a lot of the structure of this driver is vastly simpler when the IDs are all
//	known a priori. Comments in the code will try to identify some of these simplifications and
//	point out what a more complicated driver will need to do.
enum
{
	kObjectID_PlugIn					= kAudioObjectPlugInObject,
	kObjectID_Box						= 2,
	kObjectID_Device					= 3,
	kObjectID_Stream_Input				= 4,
	kObjectID_Stream_Output				= 8,
};

//	Declare the stuff that tracks the state of the plug-in, the device and its sub-objects.
//	Note that we use global variables here because this driver only ever has a single device. If
//	multiple devices were supported, this state would need to be encapsulated in one or more structs
//	so that each object's state can be tracked individually.
//	Note also that we share a single mutex across all objects to be thread safe for the same reason.
#define										kPlugIn_BundleID				"ai.kortexa.aicamera.audio.driver"
static pthread_mutex_t						gPlugIn_StateMutex				= PTHREAD_MUTEX_INITIALIZER;
static UInt32								gPlugIn_RefCount				= 0;
static AudioServerPlugInHostRef				gPlugIn_Host					= NULL;

#define										kBox_UID						"ai.kortexa.aicamera.audio.box"
static CFStringRef							gBox_Name						= NULL;
static Boolean								gBox_Acquired					= true;

#define										kDevice_UID						"ai.kortexa.aicamera.audio.device"
#define										kDevice_ModelUID				"ai.kortexa.aicamera.audio.model"
#define										kCompanionHost_BundleID		"ai.kortexa.aicamera"
#define										kAICameraDevicePropertyConsumerCount ((AudioObjectPropertySelector)0x61696363U)
static pthread_mutex_t						gDevice_IOMutex					= PTHREAD_MUTEX_INITIALIZER;
static Float64								gDevice_SampleRate				= 48000.0;
static Float64								gDevice_RequestedSampleRate		= 48000.0;
static Boolean								gDevice_ConfigurationInFlight	= false;
static UInt64								gDevice_InFlightSampleRate		= 0;
static dispatch_queue_t					gDevice_ConfigurationQueue		= NULL;
static UInt64								gDevice_IOIsRunning				= 0;
enum
{
	kDevice_RingBufferSize = 16384,
	kDevice_ChannelCount = 2,
	kDevice_MaxTrackedClients = 64
};
// Actual microphone demand is recorded only by ReadInput operations. The real-time callback
// touches this fixed lock-free table and never allocates, locks, logs, or performs IPC.
static _Atomic(UInt64)					gDevice_InputConsumerClientIDs[kDevice_MaxTrackedClients];
static _Atomic(UInt64)					gDevice_InputConsumerLastRead[kDevice_MaxTrackedClients];
static _Atomic(UInt64)					gDevice_CompanionClientIDs[kDevice_MaxTrackedClients];
static _Atomic(UInt64)					gDevice_InputConsumerOverflowLastRead = 0;
static Float64								gDevice_HostTicksPerSecond		= 1000000000.0;
// Atomic sample bits and per-slot frame tags avoid C data races between HAL input and output IO threads.
static _Alignas(64) _Atomic(UInt32)	gDevice_LoopbackSampleBits[kDevice_RingBufferSize * kDevice_ChannelCount];
static _Alignas(64) _Atomic(UInt64)	gDevice_LoopbackFrameTags[kDevice_RingBufferSize];
static _Atomic(UInt64)					gDevice_FirstOutputFrame		= UINT64_MAX;
static _Atomic(UInt64)					gDevice_LastOutputEndFrame		= 0;
static Float64								gDevice_HostTicksPerFrame		= 0.0;
static UInt64								gDevice_NumberTimeStamps		= 0;
static UInt64								gDevice_ZeroTimeStampSeed		= 1;
static Float64								gDevice_AnchorSampleTime		= 0.0;
static UInt64								gDevice_AnchorHostTime			= 0;

static bool									gStream_Input_IsActive			= true;
static bool									gStream_Output_IsActive			= true;

static void AICameraAudioDriver_SetCompanionClient(UInt32 inClientID, Boolean inIsCompanion)
{
	UInt64 theEncodedClientID = (UInt64)inClientID + 1;
	for(UInt32 theIndex = 0; theIndex < kDevice_MaxTrackedClients; ++theIndex)
	{
		UInt64 theExisting = atomic_load_explicit(
			&gDevice_CompanionClientIDs[theIndex],
			memory_order_acquire);
		if(theExisting == theEncodedClientID)
		{
			if(!inIsCompanion)
			{
				atomic_store_explicit(
					&gDevice_CompanionClientIDs[theIndex],
					0,
					memory_order_release);
			}
			return;
		}
	}
	if(!inIsCompanion) return;
	for(UInt32 theIndex = 0; theIndex < kDevice_MaxTrackedClients; ++theIndex)
	{
		UInt64 theExpected = 0;
		if(atomic_compare_exchange_strong_explicit(
			&gDevice_CompanionClientIDs[theIndex],
			&theExpected,
			theEncodedClientID,
			memory_order_acq_rel,
			memory_order_acquire) || theExpected == theEncodedClientID)
		{
			return;
		}
	}
}

static Boolean AICameraAudioDriver_IsCompanionClient(UInt32 inClientID)
{
	UInt64 theEncodedClientID = (UInt64)inClientID + 1;
	for(UInt32 theIndex = 0; theIndex < kDevice_MaxTrackedClients; ++theIndex)
	{
		if(atomic_load_explicit(
			&gDevice_CompanionClientIDs[theIndex],
			memory_order_acquire) == theEncodedClientID)
		{
			return true;
		}
	}
	return false;
}

static void AICameraAudioDriver_MarkInputConsumer(UInt32 inClientID)
{
	if(AICameraAudioDriver_IsCompanionClient(inClientID)) return;
	UInt64 theEncodedClientID = (UInt64)inClientID + 1;
	UInt64 theNow = mach_absolute_time();
	for(UInt32 theIndex = 0; theIndex < kDevice_MaxTrackedClients; ++theIndex)
	{
		UInt64 theExisting = atomic_load_explicit(
			&gDevice_InputConsumerClientIDs[theIndex],
			memory_order_acquire);
		if(theExisting == theEncodedClientID)
		{
			atomic_store_explicit(
				&gDevice_InputConsumerLastRead[theIndex],
				theNow,
				memory_order_release);
			return;
		}
	}
	for(UInt32 theIndex = 0; theIndex < kDevice_MaxTrackedClients; ++theIndex)
	{
		UInt64 theExpected = 0;
		if(atomic_compare_exchange_strong_explicit(
			&gDevice_InputConsumerClientIDs[theIndex],
			&theExpected,
			theEncodedClientID,
			memory_order_acq_rel,
			memory_order_acquire) || theExpected == theEncodedClientID)
		{
			atomic_store_explicit(
				&gDevice_InputConsumerLastRead[theIndex],
				theNow,
				memory_order_release);
			return;
		}
	}
	// Preserve safe demand when more readers exist than the bounded identity table can name.
	atomic_store_explicit(
		&gDevice_InputConsumerOverflowLastRead,
		theNow,
		memory_order_release);
}

static void AICameraAudioDriver_ClearInputConsumer(UInt32 inClientID)
{
	UInt64 theEncodedClientID = (UInt64)inClientID + 1;
	for(UInt32 theIndex = 0; theIndex < kDevice_MaxTrackedClients; ++theIndex)
	{
		UInt64 theExpected = theEncodedClientID;
		if(atomic_compare_exchange_strong_explicit(
			&gDevice_InputConsumerClientIDs[theIndex],
			&theExpected,
			0,
			memory_order_acq_rel,
			memory_order_acquire))
		{
			atomic_store_explicit(
				&gDevice_InputConsumerLastRead[theIndex],
				0,
				memory_order_release);
			return;
		}
	}
}

static UInt32 AICameraAudioDriver_CopyInputConsumerCount(void)
{
	UInt32 theCount = 0;
	UInt64 theNow = mach_absolute_time();
	UInt64 theWindow = (UInt64)gDevice_HostTicksPerSecond;
	for(UInt32 theIndex = 0; theIndex < kDevice_MaxTrackedClients; ++theIndex)
	{
		UInt64 theClientID = atomic_load_explicit(
			&gDevice_InputConsumerClientIDs[theIndex],
			memory_order_acquire);
		UInt64 theLastRead = atomic_load_explicit(
			&gDevice_InputConsumerLastRead[theIndex],
			memory_order_acquire);
		if(theClientID != 0 && theLastRead != 0 && theNow >= theLastRead &&
			theNow - theLastRead <= theWindow)
		{
			++theCount;
		}
	}
	UInt64 theOverflowRead = atomic_load_explicit(
		&gDevice_InputConsumerOverflowLastRead,
		memory_order_acquire);
	if(theOverflowRead != 0 && theNow >= theOverflowRead &&
		theNow - theOverflowRead <= theWindow)
	{
		++theCount;
	}
	return theCount;
}

static Boolean AICameraAudioDriver_CopyBoxAcquired(void)
{
	pthread_mutex_lock(&gPlugIn_StateMutex);
	Boolean theAnswer = gBox_Acquired;
	pthread_mutex_unlock(&gPlugIn_StateMutex);
	return theAnswer;
}

static Boolean AICameraAudioDriver_ClassMatchesQualifier(
	AudioClassID inClassID,
	UInt32 inQualifierDataSize,
	const void* inQualifierData)
{
	if(inQualifierDataSize == 0) return true;
	const AudioClassID* theClasses = (const AudioClassID*)inQualifierData;
	UInt32 theClassCount = inQualifierDataSize / sizeof(AudioClassID);
	for(UInt32 theIndex = 0; theIndex < theClassCount; ++theIndex)
	{
		if(theClasses[theIndex] == inClassID || theClasses[theIndex] == kAudioObjectClassID)
		{
			return true;
		}
	}
	return false;
}

static Boolean AICameraAudioDriver_IsPropertyAddressValid(
	AudioObjectID inObjectID,
	const AudioObjectPropertyAddress* inAddress)
{
	if(inAddress == NULL) return false;
	if(inObjectID == kObjectID_PlugIn || inObjectID == kObjectID_Box)
	{
		return inAddress->mScope == kAudioObjectPropertyScopeGlobal && inAddress->mElement == kAudioObjectPropertyElementMain;
	}
	if(inObjectID == kObjectID_Stream_Input || inObjectID == kObjectID_Stream_Output)
	{
		return inAddress->mScope == kAudioObjectPropertyScopeGlobal && inAddress->mElement == kAudioObjectPropertyElementMain;
	}
	if(inObjectID != kObjectID_Device) return false;
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyOwnedObjects:
		case kAudioDevicePropertyStreams:
			return inAddress->mElement == kAudioObjectPropertyElementMain &&
				(inAddress->mScope == kAudioObjectPropertyScopeGlobal || inAddress->mScope == kAudioObjectPropertyScopeInput ||
				 inAddress->mScope == kAudioObjectPropertyScopeOutput || inAddress->mScope == kAudioObjectPropertyScopePlayThrough);
		case kAudioDevicePropertyDeviceCanBeDefaultDevice:
		case kAudioDevicePropertyLatency:
		case kAudioDevicePropertySafetyOffset:
		case kAudioDevicePropertyPreferredChannelsForStereo:
		case kAudioDevicePropertyPreferredChannelLayout:
			return inAddress->mElement == kAudioObjectPropertyElementMain &&
				(inAddress->mScope == kAudioObjectPropertyScopeInput || inAddress->mScope == kAudioObjectPropertyScopeOutput);
		case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
			return inAddress->mElement == kAudioObjectPropertyElementMain && inAddress->mScope == kAudioObjectPropertyScopeOutput;
		case kAudioObjectPropertyElementName:
			return (inAddress->mScope == kAudioObjectPropertyScopeInput || inAddress->mScope == kAudioObjectPropertyScopeOutput) && inAddress->mElement <= 2;
		default:
			return inAddress->mScope == kAudioObjectPropertyScopeGlobal && inAddress->mElement == kAudioObjectPropertyElementMain;
	}
}

static void AICameraAudioDriver_DispatchSampleRateRequest(UInt64 inSampleRate);

static UInt64 AICameraAudioDriver_NextSampleRateRequestLocked(void)
{
	if(!gDevice_ConfigurationInFlight && gDevice_RequestedSampleRate != gDevice_SampleRate)
	{
		gDevice_ConfigurationInFlight = true;
		gDevice_InFlightSampleRate = (UInt64)gDevice_RequestedSampleRate;
		return gDevice_InFlightSampleRate;
	}
	return 0;
}

static void AICameraAudioDriver_DispatchSampleRateRequest(UInt64 inSampleRate)
{
	dispatch_queue_t theQueue = gDevice_ConfigurationQueue;
	if(theQueue == NULL || gPlugIn_Host == NULL) return;
	dispatch_async(theQueue, ^{
		OSStatus theStatus = gPlugIn_Host->RequestDeviceConfigurationChange(
			gPlugIn_Host, kObjectID_Device, inSampleRate, NULL);
		if(theStatus != noErr)
		{
			UInt64 theNextRequest = 0;
			pthread_mutex_lock(&gPlugIn_StateMutex);
			if(gDevice_ConfigurationInFlight && gDevice_InFlightSampleRate == inSampleRate)
			{
				gDevice_ConfigurationInFlight = false;
				gDevice_InFlightSampleRate = 0;
				if((UInt64)gDevice_RequestedSampleRate == inSampleRate)
				{
					gDevice_RequestedSampleRate = gDevice_SampleRate;
				}
				theNextRequest = AICameraAudioDriver_NextSampleRateRequestLocked();
			}
			pthread_mutex_unlock(&gPlugIn_StateMutex);
			if(theNextRequest != 0) AICameraAudioDriver_DispatchSampleRateRequest(theNextRequest);
		}
	});
}

static void AICameraAudioDriver_RequestSampleRate(Float64 inSampleRate)
{
	UInt64 theNextRequest;
	pthread_mutex_lock(&gPlugIn_StateMutex);
	gDevice_RequestedSampleRate = inSampleRate;
	theNextRequest = AICameraAudioDriver_NextSampleRateRequestLocked();
	pthread_mutex_unlock(&gPlugIn_StateMutex);
	if(theNextRequest != 0) AICameraAudioDriver_DispatchSampleRateRequest(theNextRequest);
}

//==================================================================================================
#pragma mark -
#pragma mark AudioServerPlugInDriverInterface Implementation
//==================================================================================================

#pragma mark Prototypes

//	Entry points for the COM methods. The factory must remain externally visible because
//	Core Foundation resolves its symbol by name from CFPlugInFactories.
__attribute__((visibility("default")))
void*				AICameraAudioDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
static HRESULT		AICameraAudioDriver_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG		AICameraAudioDriver_AddRef(void* inDriver);
static ULONG		AICameraAudioDriver_Release(void* inDriver);
static OSStatus		AICameraAudioDriver_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus		AICameraAudioDriver_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus		AICameraAudioDriver_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus		AICameraAudioDriver_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus		AICameraAudioDriver_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus		AICameraAudioDriver_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus		AICameraAudioDriver_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static Boolean		AICameraAudioDriver_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus		AICameraAudioDriver_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus		AICameraAudioDriver_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus		AICameraAudioDriver_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus		AICameraAudioDriver_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus		AICameraAudioDriver_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus		AICameraAudioDriver_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus		AICameraAudioDriver_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus		AICameraAudioDriver_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus		AICameraAudioDriver_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus		AICameraAudioDriver_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus		AICameraAudioDriver_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

//	Implementation
static Boolean		AICameraAudioDriver_HasPlugInProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus		AICameraAudioDriver_IsPlugInPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus		AICameraAudioDriver_GetPlugInPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus		AICameraAudioDriver_GetPlugInPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus		AICameraAudioDriver_SetPlugInPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2]);

static Boolean		AICameraAudioDriver_HasBoxProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus		AICameraAudioDriver_IsBoxPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus		AICameraAudioDriver_GetBoxPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus		AICameraAudioDriver_GetBoxPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus		AICameraAudioDriver_SetBoxPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2]);

static Boolean		AICameraAudioDriver_HasDeviceProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus		AICameraAudioDriver_IsDevicePropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus		AICameraAudioDriver_GetDevicePropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus		AICameraAudioDriver_GetDevicePropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus		AICameraAudioDriver_SetDevicePropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2]);

static Boolean		AICameraAudioDriver_HasStreamProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus		AICameraAudioDriver_IsStreamPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus		AICameraAudioDriver_GetStreamPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus		AICameraAudioDriver_GetStreamPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus		AICameraAudioDriver_SetStreamPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2]);


#pragma mark The Interface

static AudioServerPlugInDriverInterface	gAudioServerPlugInDriverInterface =
{
	NULL,
	AICameraAudioDriver_QueryInterface,
	AICameraAudioDriver_AddRef,
	AICameraAudioDriver_Release,
	AICameraAudioDriver_Initialize,
	AICameraAudioDriver_CreateDevice,
	AICameraAudioDriver_DestroyDevice,
	AICameraAudioDriver_AddDeviceClient,
	AICameraAudioDriver_RemoveDeviceClient,
	AICameraAudioDriver_PerformDeviceConfigurationChange,
	AICameraAudioDriver_AbortDeviceConfigurationChange,
	AICameraAudioDriver_HasProperty,
	AICameraAudioDriver_IsPropertySettable,
	AICameraAudioDriver_GetPropertyDataSize,
	AICameraAudioDriver_GetPropertyData,
	AICameraAudioDriver_SetPropertyData,
	AICameraAudioDriver_StartIO,
	AICameraAudioDriver_StopIO,
	AICameraAudioDriver_GetZeroTimeStamp,
	AICameraAudioDriver_WillDoIOOperation,
	AICameraAudioDriver_BeginIOOperation,
	AICameraAudioDriver_DoIOOperation,
	AICameraAudioDriver_EndIOOperation
};
static AudioServerPlugInDriverInterface*	gAudioServerPlugInDriverInterfacePtr	= &gAudioServerPlugInDriverInterface;
static AudioServerPlugInDriverRef			gAudioServerPlugInDriverRef				= &gAudioServerPlugInDriverInterfacePtr;

#pragma mark Factory

void*	AICameraAudioDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
	//	This is the CFPlugIn factory function. Its job is to create the implementation for the given
	//	type provided that the type is supported. Because this driver is simple and all its
	//	initialization is handled via static iniitalization when the bundle is loaded, all that
	//	needs to be done is to return the AudioServerPlugInDriverRef that points to the driver's
	//	interface. A more complicated driver would create any base line objects it needs to satisfy
	//	the IUnknown methods that are used to discover that actual interface to talk to the driver.
	//	The majority of the driver's initilization should be handled in the Initialize() method of
	//	the driver's AudioServerPlugInDriverInterface.

	#pragma unused(inAllocator)
    void* theAnswer = NULL;
    if(inRequestedTypeUUID != NULL && CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID))
    {
		theAnswer = gAudioServerPlugInDriverRef;
    }
    return theAnswer;
}

#pragma mark Inheritence

static HRESULT	AICameraAudioDriver_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
	//	This function is called by the HAL to get the interface to talk to the plug-in through.
	//	AudioServerPlugIns are required to support the IUnknown interface and the
	//	AudioServerPlugInDriverInterface. As it happens, all interfaces must also provide the
	//	IUnknown interface, so we can always just return the single interface we made with
	//	gAudioServerPlugInDriverInterfacePtr regardless of which one is asked for.

	//	declare the local variables
	HRESULT theAnswer = 0;
	CFUUIDRef theRequestedUUID = NULL;

	//	validate the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_QueryInterface: bad driver reference");
	FailWithAction(outInterface == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_QueryInterface: no place to store the returned interface");
	*outInterface = NULL;

	//	make a CFUUIDRef from inUUID
	theRequestedUUID = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
	FailWithAction(theRequestedUUID == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_QueryInterface: failed to create the CFUUIDRef");

	//	AudioServerPlugIns only support two interfaces, IUnknown (which has to be supported by all
	//	CFPlugIns and AudioServerPlugInDriverInterface (which is the actual interface the HAL will
	//	use).
	if(CFEqual(theRequestedUUID, IUnknownUUID) || CFEqual(theRequestedUUID, kAudioServerPlugInDriverInterfaceUUID))
	{
		pthread_mutex_lock(&gPlugIn_StateMutex);
		++gPlugIn_RefCount;
		pthread_mutex_unlock(&gPlugIn_StateMutex);
		*outInterface = gAudioServerPlugInDriverRef;
	}
	else
	{
		theAnswer = E_NOINTERFACE;
	}

	//	make sure to release the UUID we created
	CFRelease(theRequestedUUID);

Done:
	return theAnswer;
}

static ULONG	AICameraAudioDriver_AddRef(void* inDriver)
{
	//	This call returns the resulting reference count after the increment.

	//	declare the local variables
	ULONG theAnswer = 0;

	//	check the arguments
	FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "AICameraAudioDriver_AddRef: bad driver reference");

	//	decrement the refcount
	pthread_mutex_lock(&gPlugIn_StateMutex);
	if(gPlugIn_RefCount < UINT32_MAX)
	{
		++gPlugIn_RefCount;
	}
	theAnswer = gPlugIn_RefCount;
	pthread_mutex_unlock(&gPlugIn_StateMutex);

Done:
	return theAnswer;
}

static ULONG	AICameraAudioDriver_Release(void* inDriver)
{
	//	This call returns the resulting reference count after the decrement.

	//	declare the local variables
	ULONG theAnswer = 0;

	//	check the arguments
	FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "AICameraAudioDriver_Release: bad driver reference");

	//	increment the refcount
	pthread_mutex_lock(&gPlugIn_StateMutex);
	if(gPlugIn_RefCount > 0)
	{
		--gPlugIn_RefCount;
		//	Note that we don't do anything special if the refcount goes to zero as the HAL
		//	will never fully release a plug-in it opens. We keep managing the refcount so that
		//	the API semantics are correct though.
	}
	theAnswer = gPlugIn_RefCount;
	pthread_mutex_unlock(&gPlugIn_StateMutex);

Done:
	return theAnswer;
}

#pragma mark Basic Operations

static OSStatus	AICameraAudioDriver_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
	//	The job of this method is, as the name implies, to get the driver initialized. One specific
	//	thing that needs to be done is to store the AudioServerPlugInHostRef so that it can be used
	//	later. Note that when this call returns, the HAL will scan the various lists the driver
	//	maintains (such as the device list) to get the inital set of objects the driver is
	//	publishing. So, there is no need to notifiy the HAL about any objects created as part of the
	//	execution of this method.

	//	declare the local variables
	OSStatus theAnswer = 0;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_Initialize: bad driver reference");
	FailWithAction(inHost == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_Initialize: no host interface");

	//	store the AudioServerPlugInHostRef
	gPlugIn_Host = inHost;
	if(gDevice_ConfigurationQueue == NULL)
	{
		gDevice_ConfigurationQueue = dispatch_queue_create("ai.kortexa.aicamera.audio.configuration", DISPATCH_QUEUE_SERIAL);
	}
	gDevice_RequestedSampleRate = gDevice_SampleRate;
	gDevice_ConfigurationInFlight = false;
	gDevice_InFlightSampleRate = 0;

	//	initialize the box acquired property from the settings
	CFPropertyListRef theSettingsData = NULL;
	gPlugIn_Host->CopyFromStorage(gPlugIn_Host, CFSTR("box acquired"), &theSettingsData);
	if(theSettingsData != NULL)
	{
		if(CFGetTypeID(theSettingsData) == CFBooleanGetTypeID())
		{
			gBox_Acquired = CFBooleanGetValue((CFBooleanRef)theSettingsData);
		}
		else if(CFGetTypeID(theSettingsData) == CFNumberGetTypeID())
		{
			SInt32 theValue = 0;
			CFNumberGetValue((CFNumberRef)theSettingsData, kCFNumberSInt32Type, &theValue);
			gBox_Acquired = theValue ? 1 : 0;
		}
		CFRelease(theSettingsData);
	}

	//	initialize the box name from the settings
	gPlugIn_Host->CopyFromStorage(gPlugIn_Host, CFSTR("box name"), &theSettingsData);
	if(theSettingsData != NULL)
	{
		if(CFGetTypeID(theSettingsData) == CFStringGetTypeID())
		{
			gBox_Name = (CFStringRef)theSettingsData;
			CFRetain(gBox_Name);
		}
		CFRelease(theSettingsData);
	}

	//	set the box name directly as a last resort
	if(gBox_Name == NULL)
	{
		gBox_Name = CFSTR("AI Camera Audio Driver");
	}

	//	calculate the host ticks per frame
	struct mach_timebase_info theTimeBaseInfo;
	mach_timebase_info(&theTimeBaseInfo);
	Float64 theHostClockFrequency = (Float64)theTimeBaseInfo.denom / (Float64)theTimeBaseInfo.numer;
	theHostClockFrequency *= 1000000000.0;
	gDevice_HostTicksPerSecond = theHostClockFrequency;
	gDevice_HostTicksPerFrame = theHostClockFrequency / gDevice_SampleRate;

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID)
{
	//	This method is used to tell a driver that implements the Transport Manager semantics to
	//	create an AudioEndpointDevice from a set of AudioEndpoints. Since this driver is not a
	//	Transport Manager, we just check the arguments and return
	//	kAudioHardwareUnsupportedOperationError.

	#pragma unused(inDescription, inClientInfo, outDeviceObjectID)

	//	declare the local variables
	OSStatus theAnswer = kAudioHardwareUnsupportedOperationError;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_CreateDevice: bad driver reference");

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
	//	This method is used to tell a driver that implements the Transport Manager semantics to
	//	destroy an AudioEndpointDevice. Since this driver is not a Transport Manager, we just check
	//	the arguments and return kAudioHardwareUnsupportedOperationError.

	#pragma unused(inDeviceObjectID)

	//	declare the local variables
	OSStatus theAnswer = kAudioHardwareUnsupportedOperationError;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_DestroyDevice: bad driver reference");

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
	//	This method is used to inform the driver about a new client that is using the given device.
	//	This allows the device to act differently depending on who the client is. This driver does
	//	not need to track the clients using the device, so we just check the arguments and return
	//	successfully.

	//	declare the local variables
	OSStatus theAnswer = 0;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_AddDeviceClient: bad driver reference");
	FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_AddDeviceClient: bad device ID");
	FailWithAction(inClientInfo == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_AddDeviceClient: missing client info");

	AICameraAudioDriver_SetCompanionClient(
		inClientInfo->mClientID,
		inClientInfo->mBundleID != NULL &&
			CFEqual(inClientInfo->mBundleID, CFSTR(kCompanionHost_BundleID)));

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
	//	Remove stale demand even if a client disconnects without a balanced StopIO call.
	OSStatus theAnswer = 0;

	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_RemoveDeviceClient: bad driver reference");
	FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_RemoveDeviceClient: bad device ID");
	FailWithAction(inClientInfo == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_RemoveDeviceClient: missing client info");

	AICameraAudioDriver_SetCompanionClient(inClientInfo->mClientID, false);
	AICameraAudioDriver_ClearInputConsumer(inClientInfo->mClientID);

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_PerformDeviceConfigurationChange(
	AudioServerPlugInDriverRef inDriver,
	AudioObjectID inDeviceObjectID,
	UInt64 inChangeAction,
	void* inChangeInfo)
{
	#pragma unused(inChangeInfo)
	OSStatus theAnswer = 0;
	UInt64 theNextRequest = 0;
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_PerformDeviceConfigurationChange: bad driver reference");
	FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_PerformDeviceConfigurationChange: bad device ID");
	FailWithAction((inChangeAction != 44100) && (inChangeAction != 48000), theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_PerformDeviceConfigurationChange: bad sample rate");

	pthread_mutex_lock(&gPlugIn_StateMutex);
	if(!gDevice_ConfigurationInFlight || gDevice_InFlightSampleRate != inChangeAction)
	{
		theAnswer = kAudioHardwareIllegalOperationError;
		pthread_mutex_unlock(&gPlugIn_StateMutex);
		goto Done;
	}
	gDevice_SampleRate = (Float64)inChangeAction;
	gDevice_ConfigurationInFlight = false;
	gDevice_InFlightSampleRate = 0;
	theNextRequest = AICameraAudioDriver_NextSampleRateRequestLocked();
	pthread_mutex_unlock(&gPlugIn_StateMutex);

	struct mach_timebase_info theTimeBaseInfo;
	mach_timebase_info(&theTimeBaseInfo);
	Float64 theHostClockFrequency = (Float64)theTimeBaseInfo.denom / (Float64)theTimeBaseInfo.numer;
	theHostClockFrequency *= 1000000000.0;
	pthread_mutex_lock(&gDevice_IOMutex);
	gDevice_HostTicksPerFrame = theHostClockFrequency / (Float64)inChangeAction;
	pthread_mutex_unlock(&gDevice_IOMutex);
	if(theNextRequest != 0) AICameraAudioDriver_DispatchSampleRateRequest(theNextRequest);

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_AbortDeviceConfigurationChange(
	AudioServerPlugInDriverRef inDriver,
	AudioObjectID inDeviceObjectID,
	UInt64 inChangeAction,
	void* inChangeInfo)
{
	#pragma unused(inChangeInfo)
	OSStatus theAnswer = 0;
	UInt64 theNextRequest = 0;
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_AbortDeviceConfigurationChange: bad driver reference");
	FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_AbortDeviceConfigurationChange: bad device ID");
	FailWithAction((inChangeAction != 44100) && (inChangeAction != 48000), theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_AbortDeviceConfigurationChange: bad sample rate");

	pthread_mutex_lock(&gPlugIn_StateMutex);
	if(gDevice_ConfigurationInFlight && gDevice_InFlightSampleRate == inChangeAction)
	{
		gDevice_ConfigurationInFlight = false;
		gDevice_InFlightSampleRate = 0;
		if((UInt64)gDevice_RequestedSampleRate == inChangeAction)
		{
			gDevice_RequestedSampleRate = gDevice_SampleRate;
		}
		theNextRequest = AICameraAudioDriver_NextSampleRateRequestLocked();
	}
	pthread_mutex_unlock(&gPlugIn_StateMutex);
	if(theNextRequest != 0) AICameraAudioDriver_DispatchSampleRateRequest(theNextRequest);

Done:
	return theAnswer;
}

#pragma mark Property Operations

static Boolean	AICameraAudioDriver_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
	//	This method returns whether or not the given object has the given property.

	//	declare the local variables
	Boolean theAnswer = false;

	//	check the arguments
	FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "AICameraAudioDriver_HasProperty: bad driver reference");
	FailIf(inAddress == NULL, Done, "AICameraAudioDriver_HasProperty: no address");
	FailIf(!AICameraAudioDriver_IsPropertyAddressValid(inObjectID, inAddress), Done, "AICameraAudioDriver_HasProperty: invalid property address");

	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the AICameraAudioDriver_GetPropertyData() method.
	switch(inObjectID)
	{
		case kObjectID_PlugIn:
			theAnswer = AICameraAudioDriver_HasPlugInProperty(inDriver, inObjectID, inClientProcessID, inAddress);
			break;

		case kObjectID_Box:
			theAnswer = AICameraAudioDriver_HasBoxProperty(inDriver, inObjectID, inClientProcessID, inAddress);
			break;

		case kObjectID_Device:
			theAnswer = AICameraAudioDriver_HasDeviceProperty(inDriver, inObjectID, inClientProcessID, inAddress);
			break;

		case kObjectID_Stream_Input:
		case kObjectID_Stream_Output:
			theAnswer = AICameraAudioDriver_HasStreamProperty(inDriver, inObjectID, inClientProcessID, inAddress);
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
	//	This method returns whether or not the given property on the object can have its value
	//	changed.

	//	declare the local variables
	OSStatus theAnswer = 0;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_IsPropertySettable: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_IsPropertySettable: no address");
	FailWithAction(!AICameraAudioDriver_IsPropertyAddressValid(inObjectID, inAddress), theAnswer = kAudioHardwareUnknownPropertyError, Done, "AICameraAudioDriver_IsPropertySettable: invalid property address");
	FailWithAction(outIsSettable == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_IsPropertySettable: no place to put the return value");

	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the AICameraAudioDriver_GetPropertyData() method.
	switch(inObjectID)
	{
		case kObjectID_PlugIn:
			theAnswer = AICameraAudioDriver_IsPlugInPropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
			break;

		case kObjectID_Box:
			theAnswer = AICameraAudioDriver_IsBoxPropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
			break;

		case kObjectID_Device:
			theAnswer = AICameraAudioDriver_IsDevicePropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
			break;

		case kObjectID_Stream_Input:
		case kObjectID_Stream_Output:
			theAnswer = AICameraAudioDriver_IsStreamPropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
			break;

		default:
			theAnswer = kAudioHardwareBadObjectError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
	//	This method returns the byte size of the property's data.

	//	declare the local variables
	OSStatus theAnswer = 0;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_GetPropertyDataSize: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetPropertyDataSize: no address");
	FailWithAction(!AICameraAudioDriver_IsPropertyAddressValid(inObjectID, inAddress), theAnswer = kAudioHardwareUnknownPropertyError, Done, "AICameraAudioDriver_GetPropertyDataSize: invalid property address");
	FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetPropertyDataSize: no place to put the return value");

	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the AICameraAudioDriver_GetPropertyData() method.
	switch(inObjectID)
	{
		case kObjectID_PlugIn:
			theAnswer = AICameraAudioDriver_GetPlugInPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
			break;

		case kObjectID_Box:
			theAnswer = AICameraAudioDriver_GetBoxPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
			break;

		case kObjectID_Device:
			theAnswer = AICameraAudioDriver_GetDevicePropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
			break;

		case kObjectID_Stream_Input:
		case kObjectID_Stream_Output:
			theAnswer = AICameraAudioDriver_GetStreamPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
			break;

		default:
			theAnswer = kAudioHardwareBadObjectError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
	//	declare the local variables
	OSStatus theAnswer = 0;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_GetPropertyData: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetPropertyData: no address");
	FailWithAction(!AICameraAudioDriver_IsPropertyAddressValid(inObjectID, inAddress), theAnswer = kAudioHardwareUnknownPropertyError, Done, "AICameraAudioDriver_GetPropertyData: invalid property address");
	FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetPropertyData: no place to put the return value size");
	FailWithAction(outData == NULL && inDataSize > 0, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetPropertyData: no place to put the return value");

	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required.
	//
	//	Also, since most of the data that will get returned is static, there are few instances where
	//	it is necessary to lock the state mutex.
	switch(inObjectID)
	{
		case kObjectID_PlugIn:
			theAnswer = AICameraAudioDriver_GetPlugInPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
			break;

		case kObjectID_Box:
			theAnswer = AICameraAudioDriver_GetBoxPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
			break;

		case kObjectID_Device:
			theAnswer = AICameraAudioDriver_GetDevicePropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
			break;

		case kObjectID_Stream_Input:
		case kObjectID_Stream_Output:
			theAnswer = AICameraAudioDriver_GetStreamPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
			break;

		default:
			theAnswer = kAudioHardwareBadObjectError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData)
{
	//	declare the local variables
	OSStatus theAnswer = 0;
	UInt32 theNumberPropertiesChanged = 0;
	AudioObjectPropertyAddress theChangedAddresses[2];

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_SetPropertyData: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_SetPropertyData: no address");
	FailWithAction(!AICameraAudioDriver_IsPropertyAddressValid(inObjectID, inAddress), theAnswer = kAudioHardwareUnknownPropertyError, Done, "AICameraAudioDriver_SetPropertyData: invalid property address");
	FailWithAction(inDataSize > 0 && inData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_SetPropertyData: no data");

	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the AICameraAudioDriver_GetPropertyData() method.
	switch(inObjectID)
	{
		case kObjectID_PlugIn:
			theAnswer = AICameraAudioDriver_SetPlugInPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, inData, &theNumberPropertiesChanged, theChangedAddresses);
			break;

		case kObjectID_Box:
			theAnswer = AICameraAudioDriver_SetBoxPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, inData, &theNumberPropertiesChanged, theChangedAddresses);
			break;

		case kObjectID_Device:
			theAnswer = AICameraAudioDriver_SetDevicePropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, inData, &theNumberPropertiesChanged, theChangedAddresses);
			break;

		case kObjectID_Stream_Input:
		case kObjectID_Stream_Output:
			theAnswer = AICameraAudioDriver_SetStreamPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, inData, &theNumberPropertiesChanged, theChangedAddresses);
			break;

		default:
			theAnswer = kAudioHardwareBadObjectError;
			break;
	};

	//	send any notifications
	if(theNumberPropertiesChanged > 0)
	{
		gPlugIn_Host->PropertiesChanged(gPlugIn_Host, inObjectID, theNumberPropertiesChanged, theChangedAddresses);
	}

Done:
	return theAnswer;
}

#pragma mark PlugIn Property Operations

static Boolean	AICameraAudioDriver_HasPlugInProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
	//	This method returns whether or not the plug-in object has the given property.

	#pragma unused(inClientProcessID)

	//	declare the local variables
	Boolean theAnswer = false;

	//	check the arguments
	FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "AICameraAudioDriver_HasPlugInProperty: bad driver reference");
	FailIf(inAddress == NULL, Done, "AICameraAudioDriver_HasPlugInProperty: no address");
	FailIf(inObjectID != kObjectID_PlugIn, Done, "AICameraAudioDriver_HasPlugInProperty: not the plug-in object");


	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the AICameraAudioDriver_GetPlugInPropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
		case kAudioObjectPropertyClass:
		case kAudioObjectPropertyOwner:
		case kAudioObjectPropertyManufacturer:
		case kAudioObjectPropertyOwnedObjects:
		case kAudioPlugInPropertyBoxList:
		case kAudioPlugInPropertyTranslateUIDToBox:
		case kAudioPlugInPropertyDeviceList:
		case kAudioPlugInPropertyTranslateUIDToDevice:
		case kAudioPlugInPropertyResourceBundle:
			theAnswer = true;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_IsPlugInPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
	//	This method returns whether or not the given property on the plug-in object can have its
	//	value changed.

	#pragma unused(inClientProcessID)

	//	declare the local variables
	OSStatus theAnswer = 0;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_IsPlugInPropertySettable: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_IsPlugInPropertySettable: no address");
	FailWithAction(outIsSettable == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_IsPlugInPropertySettable: no place to put the return value");
	FailWithAction(inObjectID != kObjectID_PlugIn, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_IsPlugInPropertySettable: not the plug-in object");

	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the AICameraAudioDriver_GetPlugInPropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
		case kAudioObjectPropertyClass:
		case kAudioObjectPropertyOwner:
		case kAudioObjectPropertyManufacturer:
		case kAudioObjectPropertyOwnedObjects:
		case kAudioPlugInPropertyBoxList:
		case kAudioPlugInPropertyTranslateUIDToBox:
		case kAudioPlugInPropertyDeviceList:
		case kAudioPlugInPropertyTranslateUIDToDevice:
		case kAudioPlugInPropertyResourceBundle:
			*outIsSettable = false;
			break;


		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_GetPlugInPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
	//	This method returns the byte size of the property's data.

	#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

	//	declare the local variables
	OSStatus theAnswer = 0;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_GetPlugInPropertyDataSize: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetPlugInPropertyDataSize: no address");
	FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetPlugInPropertyDataSize: no place to put the return value");
	FailWithAction(inObjectID != kObjectID_PlugIn, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_GetPlugInPropertyDataSize: not the plug-in object");

	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the AICameraAudioDriver_GetPlugInPropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
			*outDataSize = sizeof(AudioClassID);
			break;

		case kAudioObjectPropertyClass:
			*outDataSize = sizeof(AudioClassID);
			break;

		case kAudioObjectPropertyOwner:
			*outDataSize = sizeof(AudioObjectID);
			break;

		case kAudioObjectPropertyManufacturer:
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioObjectPropertyOwnedObjects:
			FailWithAction(inQualifierDataSize % sizeof(AudioClassID) != 0, theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetPlugInPropertyDataSize: malformed owned-object qualifier");
			FailWithAction(inQualifierDataSize > 0 && inQualifierData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetPlugInPropertyDataSize: missing owned-object qualifier");
			{
				UInt32 theCount = AICameraAudioDriver_ClassMatchesQualifier(kAudioBoxClassID, inQualifierDataSize, inQualifierData) ? 1 : 0;
				if(AICameraAudioDriver_CopyBoxAcquired() && AICameraAudioDriver_ClassMatchesQualifier(kAudioDeviceClassID, inQualifierDataSize, inQualifierData)) ++theCount;
				*outDataSize = theCount * sizeof(AudioObjectID);
			}
			break;

		case kAudioPlugInPropertyBoxList:
			*outDataSize = sizeof(AudioObjectID);
			break;

		case kAudioPlugInPropertyTranslateUIDToBox:
			*outDataSize = sizeof(AudioObjectID);
			break;

		case kAudioPlugInPropertyDeviceList:
			if(AICameraAudioDriver_CopyBoxAcquired())
			{
				*outDataSize = sizeof(AudioObjectID);
			}
			else
			{
				*outDataSize = 0;
			}
			break;

		case kAudioPlugInPropertyTranslateUIDToDevice:
			*outDataSize = sizeof(AudioObjectID);
			break;

		case kAudioPlugInPropertyResourceBundle:
			*outDataSize = sizeof(CFStringRef);
			break;


		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_GetPlugInPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
	#pragma unused(inClientProcessID)

	//	declare the local variables
	OSStatus theAnswer = 0;
	UInt32 theNumberItemsToFetch;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_GetPlugInPropertyData: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetPlugInPropertyData: no address");
	FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetPlugInPropertyData: no place to put the return value size");
	FailWithAction(outData == NULL && inDataSize > 0, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetPlugInPropertyData: no place to put the return value");
	FailWithAction(inObjectID != kObjectID_PlugIn, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_GetPlugInPropertyData: not the plug-in object");

	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required.
	//
	//	Also, since most of the data that will get returned is static, there are few instances where
	//	it is necessary to lock the state mutex.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
			//	The base class for kAudioPlugInClassID is kAudioObjectClassID
			FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetPlugInPropertyData: not enough space for the return value of kAudioObjectPropertyBaseClass for the plug-in");
			*((AudioClassID*)outData) = kAudioObjectClassID;
			*outDataSize = sizeof(AudioClassID);
			break;

		case kAudioObjectPropertyClass:
			//	The class is always kAudioPlugInClassID for regular drivers
			FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetPlugInPropertyData: not enough space for the return value of kAudioObjectPropertyClass for the plug-in");
			*((AudioClassID*)outData) = kAudioPlugInClassID;
			*outDataSize = sizeof(AudioClassID);
			break;

		case kAudioObjectPropertyOwner:
			//	The plug-in doesn't have an owning object
			FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetPlugInPropertyData: not enough space for the return value of kAudioObjectPropertyOwner for the plug-in");
			*((AudioObjectID*)outData) = kAudioObjectUnknown;
			*outDataSize = sizeof(AudioObjectID);
			break;

		case kAudioObjectPropertyManufacturer:
			//	This is the human readable name of the maker of the plug-in.
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetPlugInPropertyData: not enough space for the return value of kAudioObjectPropertyManufacturer for the plug-in");
			*((CFStringRef*)outData) = CFSTR("Kortexa");
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioObjectPropertyOwnedObjects:
			FailWithAction(inQualifierDataSize % sizeof(AudioClassID) != 0, theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetPlugInPropertyData: malformed owned-object qualifier");
			FailWithAction(inQualifierDataSize > 0 && inQualifierData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetPlugInPropertyData: missing owned-object qualifier");
			{
				AudioObjectID theObjects[2];
				UInt32 theObjectCount = 0;
				if(AICameraAudioDriver_ClassMatchesQualifier(kAudioBoxClassID, inQualifierDataSize, inQualifierData)) theObjects[theObjectCount++] = kObjectID_Box;
				if(AICameraAudioDriver_CopyBoxAcquired() && AICameraAudioDriver_ClassMatchesQualifier(kAudioDeviceClassID, inQualifierDataSize, inQualifierData)) theObjects[theObjectCount++] = kObjectID_Device;
				theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);
				if(theNumberItemsToFetch > theObjectCount) theNumberItemsToFetch = theObjectCount;
				if(theNumberItemsToFetch > 0)
				{
					memcpy(outData, theObjects, theNumberItemsToFetch * sizeof(AudioObjectID));
				}
				*outDataSize = theNumberItemsToFetch * sizeof(AudioObjectID);
			}
			break;

		case kAudioPlugInPropertyBoxList:
			//	Calculate the number of items that have been requested. Note that this
			//	number is allowed to be smaller than the actual size of the list. In such
			//	case, only that number of items will be returned
			theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);

			//	Clamp that to the number of boxes this driver implements (which is just 1)
			if(theNumberItemsToFetch > 1)
			{
				theNumberItemsToFetch = 1;
			}

			//	Write the devices' object IDs into the return value
			if(theNumberItemsToFetch > 0)
			{
				((AudioObjectID*)outData)[0] = kObjectID_Box;
			}

			//	Return how many bytes we wrote to
			*outDataSize = theNumberItemsToFetch * sizeof(AudioObjectID);
			break;

		case kAudioPlugInPropertyTranslateUIDToBox:
			//	This property takes the CFString passed in the qualifier and converts that
			//	to the object ID of the box it corresponds to. For this driver, there is
			//	just the one box. Note that it is not an error if the string in the
			//	qualifier doesn't match any devices. In such case, kAudioObjectUnknown is
			//	the object ID to return.
			FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetPlugInPropertyData: not enough space for the return value of kAudioPlugInPropertyTranslateUIDToBox");
			FailWithAction(inQualifierDataSize != sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetPlugInPropertyData: the qualifier is the wrong size for kAudioPlugInPropertyTranslateUIDToBox");
			FailWithAction(inQualifierData == NULL, theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetPlugInPropertyData: no qualifier for kAudioPlugInPropertyTranslateUIDToBox");
			FailWithAction(*((CFStringRef*)inQualifierData) == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetPlugInPropertyData: null qualifier for kAudioPlugInPropertyTranslateUIDToBox");
			if(CFStringCompare(*((CFStringRef*)inQualifierData), CFSTR(kBox_UID), 0) == kCFCompareEqualTo)
			{
				*((AudioObjectID*)outData) = kObjectID_Box;
			}
			else
			{
				*((AudioObjectID*)outData) = kAudioObjectUnknown;
			}
			*outDataSize = sizeof(AudioObjectID);
			break;

		case kAudioPlugInPropertyDeviceList:
			//	Calculate the number of items that have been requested. Note that this
			//	number is allowed to be smaller than the actual size of the list. In such
			//	case, only that number of items will be returned
			theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);

			//	Clamp that to the number of devices this driver implements (which is just 1 if the
			//	box has been acquired)
			UInt32 theDeviceCount = AICameraAudioDriver_CopyBoxAcquired() ? 1 : 0;
			if(theNumberItemsToFetch > theDeviceCount)
			{
				theNumberItemsToFetch = theDeviceCount;
			}

			//	Write the devices' object IDs into the return value
			if(theNumberItemsToFetch > 0)
			{
				((AudioObjectID*)outData)[0] = kObjectID_Device;
			}

			//	Return how many bytes we wrote to
			*outDataSize = theNumberItemsToFetch * sizeof(AudioObjectID);
			break;

		case kAudioPlugInPropertyTranslateUIDToDevice:
			//	This property takes the CFString passed in the qualifier and converts that
			//	to the object ID of the device it corresponds to. For this driver, there is
			//	just the one device. Note that it is not an error if the string in the
			//	qualifier doesn't match any devices. In such case, kAudioObjectUnknown is
			//	the object ID to return.
			FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetPlugInPropertyData: not enough space for the return value of kAudioPlugInPropertyTranslateUIDToDevice");
			FailWithAction(inQualifierDataSize != sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetPlugInPropertyData: the qualifier is the wrong size for kAudioPlugInPropertyTranslateUIDToDevice");
			FailWithAction(inQualifierData == NULL, theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetPlugInPropertyData: no qualifier for kAudioPlugInPropertyTranslateUIDToDevice");
			FailWithAction(*((CFStringRef*)inQualifierData) == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetPlugInPropertyData: null qualifier for kAudioPlugInPropertyTranslateUIDToDevice");
			if(AICameraAudioDriver_CopyBoxAcquired() && CFStringCompare(*((CFStringRef*)inQualifierData), CFSTR(kDevice_UID), 0) == kCFCompareEqualTo)
			{
				*((AudioObjectID*)outData) = kObjectID_Device;
			}
			else
			{
				*((AudioObjectID*)outData) = kAudioObjectUnknown;
			}
			*outDataSize = sizeof(AudioObjectID);
			break;

		case kAudioPlugInPropertyResourceBundle:
			//	The resource bundle is a path relative to the path of the plug-in's bundle.
			//	To specify that the plug-in bundle itself should be used, we just return the
			//	empty string.
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetPlugInPropertyData: not enough space for the return value of kAudioPlugInPropertyResourceBundle");
			*((CFStringRef*)outData) = CFSTR("");
			*outDataSize = sizeof(CFStringRef);
			break;


		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_SetPlugInPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2])
{
	#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData, inDataSize, inData)

	//	declare the local variables
	OSStatus theAnswer = 0;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_SetPlugInPropertyData: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_SetPlugInPropertyData: no address");
	FailWithAction(outNumberPropertiesChanged == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_SetPlugInPropertyData: no place to return the number of properties that changed");
	FailWithAction(outChangedAddresses == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_SetPlugInPropertyData: no place to return the properties that changed");
	FailWithAction(inObjectID != kObjectID_PlugIn, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_SetPlugInPropertyData: not the plug-in object");

	//	initialize the returned number of changed properties
	*outNumberPropertiesChanged = 0;

	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the AICameraAudioDriver_GetPlugInPropertyData() method.
	switch(inAddress->mSelector)
	{

		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

#pragma mark Box Property Operations

static Boolean	AICameraAudioDriver_HasBoxProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
	//	This method returns whether or not the box object has the given property.

	#pragma unused(inClientProcessID)

	//	declare the local variables
	Boolean theAnswer = false;

	//	check the arguments
	FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "AICameraAudioDriver_HasBoxProperty: bad driver reference");
	FailIf(inAddress == NULL, Done, "AICameraAudioDriver_HasBoxProperty: no address");
	FailIf(inObjectID != kObjectID_Box, Done, "AICameraAudioDriver_HasBoxProperty: not the box object");


	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the AICameraAudioDriver_GetBoxPropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
		case kAudioObjectPropertyClass:
		case kAudioObjectPropertyOwner:
		case kAudioObjectPropertyName:
		case kAudioObjectPropertyModelName:
		case kAudioObjectPropertyManufacturer:
		case kAudioObjectPropertyOwnedObjects:
		case kAudioObjectPropertyIdentify:
		case kAudioObjectPropertySerialNumber:
		case kAudioObjectPropertyFirmwareVersion:
		case kAudioBoxPropertyBoxUID:
		case kAudioBoxPropertyTransportType:
		case kAudioBoxPropertyHasAudio:
		case kAudioBoxPropertyHasVideo:
		case kAudioBoxPropertyHasMIDI:
		case kAudioBoxPropertyIsProtected:
		case kAudioBoxPropertyAcquired:
		case kAudioBoxPropertyAcquisitionFailed:
		case kAudioBoxPropertyDeviceList:
			theAnswer = true;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_IsBoxPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
	//	This method returns whether or not the given property on the plug-in object can have its
	//	value changed.

	#pragma unused(inClientProcessID)

	//	declare the local variables
	OSStatus theAnswer = 0;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_IsBoxPropertySettable: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_IsBoxPropertySettable: no address");
	FailWithAction(outIsSettable == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_IsBoxPropertySettable: no place to put the return value");
	FailWithAction(inObjectID != kObjectID_Box, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_IsBoxPropertySettable: not the plug-in object");

	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the AICameraAudioDriver_GetBoxPropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
		case kAudioObjectPropertyClass:
		case kAudioObjectPropertyOwner:
		case kAudioObjectPropertyModelName:
		case kAudioObjectPropertyManufacturer:
		case kAudioObjectPropertyOwnedObjects:
		case kAudioObjectPropertySerialNumber:
		case kAudioObjectPropertyFirmwareVersion:
		case kAudioBoxPropertyBoxUID:
		case kAudioBoxPropertyTransportType:
		case kAudioBoxPropertyHasAudio:
		case kAudioBoxPropertyHasVideo:
		case kAudioBoxPropertyHasMIDI:
		case kAudioBoxPropertyIsProtected:
		case kAudioBoxPropertyAcquisitionFailed:
		case kAudioBoxPropertyDeviceList:
			*outIsSettable = false;
			break;

		case kAudioObjectPropertyName:
		case kAudioObjectPropertyIdentify:
		case kAudioBoxPropertyAcquired:
			*outIsSettable = true;
			break;

		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_GetBoxPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
	//	This method returns the byte size of the property's data.

	#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

	//	declare the local variables
	OSStatus theAnswer = 0;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_GetBoxPropertyDataSize: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetBoxPropertyDataSize: no address");
	FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetBoxPropertyDataSize: no place to put the return value");
	FailWithAction(inObjectID != kObjectID_Box, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_GetBoxPropertyDataSize: not the plug-in object");

	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the AICameraAudioDriver_GetBoxPropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
			*outDataSize = sizeof(AudioClassID);
			break;

		case kAudioObjectPropertyClass:
			*outDataSize = sizeof(AudioClassID);
			break;

		case kAudioObjectPropertyOwner:
			*outDataSize = sizeof(AudioObjectID);
			break;

		case kAudioObjectPropertyName:
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioObjectPropertyModelName:
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioObjectPropertyManufacturer:
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioObjectPropertyOwnedObjects:
			*outDataSize = 0;
			break;

		case kAudioObjectPropertyIdentify:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioObjectPropertySerialNumber:
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioObjectPropertyFirmwareVersion:
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioBoxPropertyBoxUID:
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioBoxPropertyTransportType:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioBoxPropertyHasAudio:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioBoxPropertyHasVideo:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioBoxPropertyHasMIDI:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioBoxPropertyIsProtected:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioBoxPropertyAcquired:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioBoxPropertyAcquisitionFailed:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioBoxPropertyDeviceList:
			{
				pthread_mutex_lock(&gPlugIn_StateMutex);
				*outDataSize = gBox_Acquired ? sizeof(AudioObjectID) : 0;
				pthread_mutex_unlock(&gPlugIn_StateMutex);
			}
			break;

		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_GetBoxPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
	#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

	//	declare the local variables
	OSStatus theAnswer = 0;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_GetBoxPropertyData: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetBoxPropertyData: no address");
	FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetBoxPropertyData: no place to put the return value size");
	FailWithAction(outData == NULL && inDataSize > 0, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetBoxPropertyData: no place to put the return value");
	FailWithAction(inObjectID != kObjectID_Box, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_GetBoxPropertyData: not the plug-in object");

	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required.
	//
	//	Also, since most of the data that will get returned is static, there are few instances where
	//	it is necessary to lock the state mutex.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
			//	The base class for kAudioBoxClassID is kAudioObjectClassID
			FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyBaseClass for the box");
			*((AudioClassID*)outData) = kAudioObjectClassID;
			*outDataSize = sizeof(AudioClassID);
			break;

		case kAudioObjectPropertyClass:
			//	The class is always kAudioBoxClassID for regular drivers
			FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyClass for the box");
			*((AudioClassID*)outData) = kAudioBoxClassID;
			*outDataSize = sizeof(AudioClassID);
			break;

		case kAudioObjectPropertyOwner:
			//	The owner is the plug-in object
			FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyOwner for the box");
			*((AudioObjectID*)outData) = kObjectID_PlugIn;
			*outDataSize = sizeof(AudioObjectID);
			break;

		case kAudioObjectPropertyName:
			//	This is the human readable name of the maker of the box.
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyManufacturer for the box");
			pthread_mutex_lock(&gPlugIn_StateMutex);
			*((CFStringRef*)outData) = gBox_Name;
			if(*((CFStringRef*)outData) != NULL)
			{
				CFRetain(*((CFStringRef*)outData));
			}
			pthread_mutex_unlock(&gPlugIn_StateMutex);
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioObjectPropertyModelName:
			//	This is the human readable name of the maker of the box.
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyManufacturer for the box");
			*((CFStringRef*)outData) = CFSTR("AI Camera Microphone");
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioObjectPropertyManufacturer:
			//	This is the human readable name of the maker of the box.
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyManufacturer for the box");
			*((CFStringRef*)outData) = CFSTR("Kortexa");
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioObjectPropertyOwnedObjects:
			//	This returns the objects directly owned by the object. Boxes don't own anything.
			*outDataSize = 0;
			break;

		case kAudioObjectPropertyIdentify:
			//	This is used to highling the device in the UI, but it's value has no meaning
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyIdentify for the box");
			*((UInt32*)outData) = 0;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioObjectPropertySerialNumber:
			//	This is the human readable serial number of the box.
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertySerialNumber for the box");
			*((CFStringRef*)outData) = CFSTR("00000001");
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioObjectPropertyFirmwareVersion:
			//	This is the human readable firmware version of the box.
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyFirmwareVersion for the box");
			*((CFStringRef*)outData) = CFSTR("1.0");
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioBoxPropertyBoxUID:
			//	Boxes have UIDs the same as devices
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetBoxPropertyData: not enough space for the return value of kAudioObjectPropertyManufacturer for the box");
			*((CFStringRef*)outData) = CFSTR(kBox_UID);
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioBoxPropertyTransportType:
			//	This value represents how the device is attached to the system. This can be
			//	any 32 bit integer, but common values for this property are defined in
			//	<CoreAudio/AudioHardwareBase.h>
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetBoxPropertyData: not enough space for the return value of kAudioDevicePropertyTransportType for the box");
			*((UInt32*)outData) = kAudioDeviceTransportTypeVirtual;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioBoxPropertyHasAudio:
			//	Indicates whether or not the box has audio capabilities
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetBoxPropertyData: not enough space for the return value of kAudioBoxPropertyHasAudio for the box");
			*((UInt32*)outData) = 1;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioBoxPropertyHasVideo:
			//	Indicates whether or not the box has video capabilities
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetBoxPropertyData: not enough space for the return value of kAudioBoxPropertyHasVideo for the box");
			*((UInt32*)outData) = 0;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioBoxPropertyHasMIDI:
			//	Indicates whether or not the box has MIDI capabilities
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetBoxPropertyData: not enough space for the return value of kAudioBoxPropertyHasMIDI for the box");
			*((UInt32*)outData) = 0;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioBoxPropertyIsProtected:
			//	Indicates whether or not the box has requires authentication to use
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetBoxPropertyData: not enough space for the return value of kAudioBoxPropertyIsProtected for the box");
			*((UInt32*)outData) = 0;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioBoxPropertyAcquired:
			//	When set to a non-zero value, the device is acquired for use by the local machine
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetBoxPropertyData: not enough space for the return value of kAudioBoxPropertyAcquired for the box");
			pthread_mutex_lock(&gPlugIn_StateMutex);
			*((UInt32*)outData) = gBox_Acquired ? 1 : 0;
			pthread_mutex_unlock(&gPlugIn_StateMutex);
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioBoxPropertyAcquisitionFailed:
			//	This is used for notifications to say when an attempt to acquire a device has failed.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetBoxPropertyData: not enough space for the return value of kAudioBoxPropertyAcquisitionFailed for the box");
			*((UInt32*)outData) = 0;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioBoxPropertyDeviceList:
			//	This is used to indicate which devices came from this box.
			//	Copy the state while locked; never jump to Done while holding the mutex.
			pthread_mutex_lock(&gPlugIn_StateMutex);
			Boolean theBoxIsAcquired = gBox_Acquired;
			pthread_mutex_unlock(&gPlugIn_StateMutex);
			if(theBoxIsAcquired)
			{
				FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetBoxPropertyData: not enough space for the return value of kAudioBoxPropertyDeviceList for the box");
				*((AudioObjectID*)outData) = kObjectID_Device;
				*outDataSize = sizeof(AudioObjectID);
			}
			else
			{
				*outDataSize = 0;
			}
			break;

		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_SetBoxPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2])
{
	#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData, inDataSize, inData)

	//	declare the local variables
	OSStatus theAnswer = 0;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_SetBoxPropertyData: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_SetBoxPropertyData: no address");
	FailWithAction(outNumberPropertiesChanged == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_SetBoxPropertyData: no place to return the number of properties that changed");
	FailWithAction(outChangedAddresses == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_SetBoxPropertyData: no place to return the properties that changed");
	FailWithAction(inObjectID != kObjectID_Box, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_SetBoxPropertyData: not the box object");

	//	initialize the returned number of changed properties
	*outNumberPropertiesChanged = 0;

	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the AICameraAudioDriver_GetPlugInPropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyName:
			//	Boxes should allow their name to be editable
			{
				FailWithAction(inDataSize != sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_SetBoxPropertyData: wrong size for the data for kAudioObjectPropertyName");
				FailWithAction(inData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_SetBoxPropertyData: no data to set for kAudioObjectPropertyName");
				CFStringRef theNewName = *((CFStringRef*)inData);
				FailWithAction(theNewName == NULL || CFGetTypeID(theNewName) != CFStringGetTypeID(), theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_SetBoxPropertyData: invalid name");
				CFRetain(theNewName);
				pthread_mutex_lock(&gPlugIn_StateMutex);
				CFStringRef theOldName = gBox_Name;
				gBox_Name = theNewName;
				pthread_mutex_unlock(&gPlugIn_StateMutex);
				if(theOldName != NULL)
				{
					CFRelease(theOldName);
				}
				gPlugIn_Host->WriteToStorage(gPlugIn_Host, CFSTR("box name"), theNewName);
				*outNumberPropertiesChanged = 1;
				outChangedAddresses[0].mSelector = kAudioObjectPropertyName;
				outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
                outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
			}
			break;

		case kAudioObjectPropertyIdentify:
			//	since we don't have any actual hardware to flash, we will schedule a notificaiton for
			//	this property off into the future as a testing thing. Note that a real implementation
			//	of this property should only send the notificaiton if the hardware wants the app to
			//	flash it's UI for the device.
			{
				syslog(LOG_NOTICE, "The identify property has been set on the box implemented by the AI Camera Audio Driver.");
				FailWithAction(inDataSize != sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_SetBoxPropertyData: wrong size for the data for kAudioObjectPropertyIdentify");
				dispatch_after(dispatch_time(0, 2ULL * 1000ULL * 1000ULL * 1000ULL), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),	^()
																																		{
																																			AudioObjectPropertyAddress theAddress = { kAudioObjectPropertyIdentify, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
																																			gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Box, 1, &theAddress);
																																		});
			}
			break;

		case kAudioBoxPropertyAcquired:
			//	Acquiring the box publishes its device.
			{
				FailWithAction(inDataSize != sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_SetBoxPropertyData: wrong size for the data for kAudioBoxPropertyAcquired");
				FailWithAction(inData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_SetBoxPropertyData: no data for kAudioBoxPropertyAcquired");
				Boolean theNewAcquiredValue = *((const UInt32*)inData) != 0;
				pthread_mutex_lock(&gPlugIn_StateMutex);
				Boolean didChange = gBox_Acquired != theNewAcquiredValue;
				gBox_Acquired = theNewAcquiredValue;
				pthread_mutex_unlock(&gPlugIn_StateMutex);
				if(didChange)
				{
					gPlugIn_Host->WriteToStorage(gPlugIn_Host, CFSTR("box acquired"), theNewAcquiredValue ? kCFBooleanTrue : kCFBooleanFalse);
					*outNumberPropertiesChanged = 2;
					outChangedAddresses[0] = (AudioObjectPropertyAddress){ kAudioBoxPropertyAcquired, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
					outChangedAddresses[1] = (AudioObjectPropertyAddress){ kAudioBoxPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
					dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
						AudioObjectPropertyAddress theAddresses[2] = {
							{ kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
							{ kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
						};
						gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_PlugIn, 2, theAddresses);
					});
				}
			}
			break;

		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

#pragma mark Device Property Operations

static Boolean	AICameraAudioDriver_HasDeviceProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
	//	This method returns whether or not the given object has the given property.

	#pragma unused(inClientProcessID)

	//	declare the local variables
	Boolean theAnswer = false;

	//	check the arguments
	FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "AICameraAudioDriver_HasDeviceProperty: bad driver reference");
	FailIf(inAddress == NULL, Done, "AICameraAudioDriver_HasDeviceProperty: no address");
	FailIf(inObjectID != kObjectID_Device, Done, "AICameraAudioDriver_HasDeviceProperty: not the device object");

	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the AICameraAudioDriver_GetDevicePropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
		case kAudioObjectPropertyClass:
		case kAudioObjectPropertyCustomPropertyInfoList:
		case kAudioObjectPropertyOwner:
		case kAudioObjectPropertyName:
		case kAudioObjectPropertyManufacturer:
		case kAudioDevicePropertyDeviceUID:
		case kAudioDevicePropertyModelUID:
		case kAudioDevicePropertyTransportType:
		case kAudioDevicePropertyRelatedDevices:
		case kAudioDevicePropertyClockDomain:
		case kAudioDevicePropertyDeviceIsAlive:
		case kAudioDevicePropertyDeviceIsRunning:
		case kAICameraDevicePropertyConsumerCount:
		case kAudioDevicePropertyNominalSampleRate:
		case kAudioDevicePropertyAvailableNominalSampleRates:
		case kAudioDevicePropertyIsHidden:
		case kAudioDevicePropertyZeroTimeStampPeriod:
			theAnswer = true;
			break;

		case kAudioObjectPropertyOwnedObjects:
		case kAudioDevicePropertyStreams:
			theAnswer = inAddress->mScope == kAudioObjectPropertyScopeGlobal ||
				inAddress->mScope == kAudioObjectPropertyScopeInput ||
				inAddress->mScope == kAudioObjectPropertyScopeOutput ||
				inAddress->mScope == kAudioObjectPropertyScopePlayThrough;
			break;

		case kAudioObjectPropertyControlList:
			theAnswer = inAddress->mScope == kAudioObjectPropertyScopeGlobal;
			break;

		case kAudioDevicePropertyDeviceCanBeDefaultDevice:
		case kAudioDevicePropertyLatency:
		case kAudioDevicePropertySafetyOffset:
		case kAudioDevicePropertyPreferredChannelsForStereo:
		case kAudioDevicePropertyPreferredChannelLayout:
			theAnswer = (inAddress->mScope == kAudioObjectPropertyScopeInput) || (inAddress->mScope == kAudioObjectPropertyScopeOutput);
			break;

		case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
			theAnswer = inAddress->mScope == kAudioObjectPropertyScopeOutput;
			break;

		case kAudioObjectPropertyElementName:
			theAnswer = inAddress->mElement <= 2;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_IsDevicePropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
	//	This method returns whether or not the given property on the object can have its value
	//	changed.

	#pragma unused(inClientProcessID)

	//	declare the local variables
	OSStatus theAnswer = 0;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_IsDevicePropertySettable: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_IsDevicePropertySettable: no address");
	FailWithAction(outIsSettable == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_IsDevicePropertySettable: no place to put the return value");
	FailWithAction(inObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_IsDevicePropertySettable: not the device object");

	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the AICameraAudioDriver_GetDevicePropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
		case kAudioObjectPropertyClass:
		case kAudioObjectPropertyCustomPropertyInfoList:
		case kAudioObjectPropertyOwner:
		case kAudioObjectPropertyName:
		case kAudioObjectPropertyManufacturer:
		case kAudioObjectPropertyElementName:
		case kAudioObjectPropertyOwnedObjects:
		case kAudioDevicePropertyDeviceUID:
		case kAudioDevicePropertyModelUID:
		case kAudioDevicePropertyTransportType:
		case kAudioDevicePropertyRelatedDevices:
		case kAudioDevicePropertyClockDomain:
		case kAudioDevicePropertyDeviceIsAlive:
		case kAudioDevicePropertyDeviceIsRunning:
		case kAICameraDevicePropertyConsumerCount:
		case kAudioDevicePropertyDeviceCanBeDefaultDevice:
		case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
		case kAudioDevicePropertyLatency:
		case kAudioDevicePropertyStreams:
		case kAudioObjectPropertyControlList:
		case kAudioDevicePropertySafetyOffset:
		case kAudioDevicePropertyAvailableNominalSampleRates:
		case kAudioDevicePropertyIsHidden:
		case kAudioDevicePropertyPreferredChannelsForStereo:
		case kAudioDevicePropertyPreferredChannelLayout:
		case kAudioDevicePropertyZeroTimeStampPeriod:
			*outIsSettable = false;
			break;

		case kAudioDevicePropertyNominalSampleRate:
			*outIsSettable = true;
			break;

		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_GetDevicePropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
	//	This method returns the byte size of the property's data.

	#pragma unused(inClientProcessID, inQualifierData)

	//	declare the local variables
	OSStatus theAnswer = 0;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_GetDevicePropertyDataSize: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetDevicePropertyDataSize: no address");
	FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetDevicePropertyDataSize: no place to put the return value");
	FailWithAction(inObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_GetDevicePropertyDataSize: not the device object");

	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the AICameraAudioDriver_GetDevicePropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
			*outDataSize = sizeof(AudioClassID);
			break;

		case kAudioObjectPropertyClass:
			*outDataSize = sizeof(AudioClassID);
			break;

		case kAudioObjectPropertyCustomPropertyInfoList:
			*outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo);
			break;

		case kAudioObjectPropertyOwner:
			*outDataSize = sizeof(AudioObjectID);
			break;

		case kAudioObjectPropertyName:
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioObjectPropertyManufacturer:
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioObjectPropertyElementName:
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioObjectPropertyOwnedObjects:
			FailWithAction(inQualifierDataSize % sizeof(AudioClassID) != 0, theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyDataSize: malformed owned-object qualifier");
			FailWithAction(inQualifierDataSize > 0 && inQualifierData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetDevicePropertyDataSize: missing owned-object qualifier");
			{
				Boolean includeStreams = AICameraAudioDriver_ClassMatchesQualifier(kAudioStreamClassID, inQualifierDataSize, inQualifierData);
				switch(inAddress->mScope)
				{
					case kAudioObjectPropertyScopeGlobal: *outDataSize = includeStreams ? 2 * sizeof(AudioObjectID) : 0; break;
					case kAudioObjectPropertyScopeInput:
					case kAudioObjectPropertyScopeOutput: *outDataSize = includeStreams ? sizeof(AudioObjectID) : 0; break;
					case kAudioObjectPropertyScopePlayThrough: *outDataSize = 0; break;
					default: theAnswer = kAudioHardwareUnknownPropertyError; break;
				}
			}
			break;

		case kAudioDevicePropertyDeviceUID:
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioDevicePropertyModelUID:
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioDevicePropertyTransportType:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyRelatedDevices:
			*outDataSize = sizeof(AudioObjectID);
			break;

		case kAudioDevicePropertyClockDomain:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyDeviceIsAlive:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyDeviceIsRunning:
			*outDataSize = sizeof(UInt32);
			break;

		case kAICameraDevicePropertyConsumerCount:
			FailWithAction(inQualifierDataSize != 0, theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyDataSize: the consumer count does not accept a qualifier");
			*outDataSize = sizeof(CFPropertyListRef);
			break;

		case kAudioDevicePropertyDeviceCanBeDefaultDevice:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyLatency:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyStreams:
			switch(inAddress->mScope)
			{
				case kAudioObjectPropertyScopeGlobal: *outDataSize = 2 * sizeof(AudioObjectID); break;
				case kAudioObjectPropertyScopeInput:
				case kAudioObjectPropertyScopeOutput: *outDataSize = sizeof(AudioObjectID); break;
				case kAudioObjectPropertyScopePlayThrough: *outDataSize = 0; break;
				default: theAnswer = kAudioHardwareUnknownPropertyError; break;
			}
			break;

		case kAudioObjectPropertyControlList:
			*outDataSize = 0;
			break;

		case kAudioDevicePropertySafetyOffset:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyNominalSampleRate:
			*outDataSize = sizeof(Float64);
			break;

		case kAudioDevicePropertyAvailableNominalSampleRates:
			*outDataSize = 2 * sizeof(AudioValueRange);
			break;

		case kAudioDevicePropertyIsHidden:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyPreferredChannelsForStereo:
			*outDataSize = 2 * sizeof(UInt32);
			break;

		case kAudioDevicePropertyPreferredChannelLayout:
			*outDataSize = offsetof(AudioChannelLayout, mChannelDescriptions) + (2 * sizeof(AudioChannelDescription));
			break;

		case kAudioDevicePropertyZeroTimeStampPeriod:
			*outDataSize = sizeof(UInt32);
			break;


		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_GetDevicePropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
	#pragma unused(inClientProcessID, inQualifierData)

	//	declare the local variables
	OSStatus theAnswer = 0;
	UInt32 theNumberItemsToFetch;
	UInt32 theItemIndex;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_GetDevicePropertyData: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetDevicePropertyData: no address");
	FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetDevicePropertyData: no place to put the return value size");
	FailWithAction(outData == NULL && inDataSize > 0, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetDevicePropertyData: no place to put the return value");
	FailWithAction(inObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_GetDevicePropertyData: not the device object");

	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required.
	//
	//	Also, since most of the data that will get returned is static, there are few instances where
	//	it is necessary to lock the state mutex.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
			//	The base class for kAudioDeviceClassID is kAudioObjectClassID
			FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyData: not enough space for the return value of kAudioObjectPropertyBaseClass for the device");
			*((AudioClassID*)outData) = kAudioObjectClassID;
			*outDataSize = sizeof(AudioClassID);
			break;

		case kAudioObjectPropertyClass:
			//	The class is always kAudioDeviceClassID for devices created by drivers
			FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyData: not enough space for the return value of kAudioObjectPropertyClass for the device");
			*((AudioClassID*)outData) = kAudioDeviceClassID;
			*outDataSize = sizeof(AudioClassID);
			break;

		case kAudioObjectPropertyCustomPropertyInfoList:
			FailWithAction(inDataSize < sizeof(AudioServerPlugInCustomPropertyInfo), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyData: not enough space for the custom property info list");
			((AudioServerPlugInCustomPropertyInfo*)outData)->mSelector = kAICameraDevicePropertyConsumerCount;
			((AudioServerPlugInCustomPropertyInfo*)outData)->mPropertyDataType = kAudioServerPlugInCustomPropertyDataTypeCFPropertyList;
			((AudioServerPlugInCustomPropertyInfo*)outData)->mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;
			*outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo);
			break;

		case kAudioObjectPropertyOwner:
			//	The device's owner is the plug-in object
			FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyData: not enough space for the return value of kAudioObjectPropertyOwner for the device");
			*((AudioObjectID*)outData) = kObjectID_PlugIn;
			*outDataSize = sizeof(AudioObjectID);
			break;

		case kAudioObjectPropertyName:
			//	This is the human readable name of the device.
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyData: not enough space for the return value of kAudioObjectPropertyName for the device");
			*((CFStringRef*)outData) = CFSTR("DeviceName");
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioObjectPropertyManufacturer:
			//	This is the human readable name of the maker of the plug-in.
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyData: not enough space for the return value of kAudioObjectPropertyManufacturer for the device");
			*((CFStringRef*)outData) = CFSTR("ManufacturerName");
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioObjectPropertyElementName:
			//	This is the human readable name of the maker of the plug-in.
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyData: not enough space for the return value of kAudioObjectPropertyElementName for the device");
			switch(inAddress->mElement)
			{
				case 0:
					*((CFStringRef*)outData) = CFSTR("MasterElementName");
					break;

				case 1:
					*((CFStringRef*)outData) = CFSTR("LeftElementName");
					break;

				case 2:
					*((CFStringRef*)outData) = CFSTR("RightElementName");
					break;

				default:
					*((CFStringRef*)outData) = CFSTR("unknown");
					break;

			};
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioObjectPropertyOwnedObjects:
			FailWithAction(inQualifierDataSize % sizeof(AudioClassID) != 0, theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyData: malformed owned-object qualifier");
			FailWithAction(inQualifierDataSize > 0 && inQualifierData == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetDevicePropertyData: missing owned-object qualifier");
			theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);
			if(!AICameraAudioDriver_ClassMatchesQualifier(kAudioStreamClassID, inQualifierDataSize, inQualifierData)) theNumberItemsToFetch = 0;
			switch(inAddress->mScope)
			{
				case kAudioObjectPropertyScopeGlobal:
					theNumberItemsToFetch = theNumberItemsToFetch > 2 ? 2 : theNumberItemsToFetch;
					if(theNumberItemsToFetch > 0) ((AudioObjectID*)outData)[0] = kObjectID_Stream_Input;
					if(theNumberItemsToFetch > 1) ((AudioObjectID*)outData)[1] = kObjectID_Stream_Output;
					break;
				case kAudioObjectPropertyScopeInput:
					theNumberItemsToFetch = theNumberItemsToFetch > 0 ? 1 : 0;
					if(theNumberItemsToFetch > 0) ((AudioObjectID*)outData)[0] = kObjectID_Stream_Input;
					break;
				case kAudioObjectPropertyScopeOutput:
					theNumberItemsToFetch = theNumberItemsToFetch > 0 ? 1 : 0;
					if(theNumberItemsToFetch > 0) ((AudioObjectID*)outData)[0] = kObjectID_Stream_Output;
					break;
				case kAudioObjectPropertyScopePlayThrough: theNumberItemsToFetch = 0; break;
				default: theNumberItemsToFetch = 0; theAnswer = kAudioHardwareUnknownPropertyError; break;
			}
			*outDataSize = theNumberItemsToFetch * sizeof(AudioObjectID);
			break;

		case kAudioDevicePropertyDeviceUID:
			//	This is a CFString that is a persistent token that can identify the same
			//	audio device across boot sessions. Note that two instances of the same
			//	device must have different values for this property.
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyDeviceUID for the device");
			*((CFStringRef*)outData) = CFSTR(kDevice_UID);
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioDevicePropertyModelUID:
			//	This is a CFString that is a persistent token that can identify audio
			//	devices that are the same kind of device. Note that two instances of the
			//	save device must have the same value for this property.
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyModelUID for the device");
			*((CFStringRef*)outData) = CFSTR(kDevice_ModelUID);
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioDevicePropertyTransportType:
			//	This value represents how the device is attached to the system. This can be
			//	any 32 bit integer, but common values for this property are defined in
			//	<CoreAudio/AudioHardwareBase.h>
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyTransportType for the device");
			*((UInt32*)outData) = kAudioDeviceTransportTypeVirtual;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyRelatedDevices:
			//	The related devices property identifys device objects that are very closely
			//	related. Generally, this is for relating devices that are packaged together
			//	in the hardware such as when the input side and the output side of a piece
			//	of hardware can be clocked separately and therefore need to be represented
			//	as separate AudioDevice objects. In such case, both devices would report
			//	that they are related to each other. Note that at minimum, a device is
			//	related to itself, so this list will always be at least one item long.

			//	Calculate the number of items that have been requested. Note that this
			//	number is allowed to be smaller than the actual size of the list. In such
			//	case, only that number of items will be returned
			theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);

			//	we only have the one device...
			if(theNumberItemsToFetch > 1)
			{
				theNumberItemsToFetch = 1;
			}

			//	Write the devices' object IDs into the return value
			if(theNumberItemsToFetch > 0)
			{
				((AudioObjectID*)outData)[0] = kObjectID_Device;
			}

			//	report how much we wrote
			*outDataSize = theNumberItemsToFetch * sizeof(AudioObjectID);
			break;

		case kAudioDevicePropertyClockDomain:
			//	This property allows the device to declare what other devices it is
			//	synchronized with in hardware. The way it works is that if two devices have
			//	the same value for this property and the value is not zero, then the two
			//	devices are synchronized in hardware. Note that a device that either can't
			//	be synchronized with others or doesn't know should return 0 for this
			//	property.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyClockDomain for the device");
			*((UInt32*)outData) = 0;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyDeviceIsAlive:
			//	This property returns whether or not the device is alive. Note that it is
			//	note uncommon for a device to be dead but still momentarily availble in the
			//	device list. In the case of this device, it will always be alive.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyDeviceIsAlive for the device");
			*((UInt32*)outData) = 1;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyDeviceIsRunning:
			//	This property returns whether or not IO is running for the device. Note that
			//	we need to take both the state lock to check this value for thread safety.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyDeviceIsRunning for the device");
			pthread_mutex_lock(&gPlugIn_StateMutex);
			*((UInt32*)outData) = ((gDevice_IOIsRunning > 0) > 0) ? 1 : 0;
			pthread_mutex_unlock(&gPlugIn_StateMutex);
			*outDataSize = sizeof(UInt32);
			break;

		case kAICameraDevicePropertyConsumerCount:
			{
				FailWithAction(inQualifierDataSize != 0, theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyData: the consumer count does not accept a qualifier");
				SInt32 theConsumerCount = (SInt32)AICameraAudioDriver_CopyInputConsumerCount();
				CFNumberRef theConsumerCountValue;
				FailWithAction(inDataSize < sizeof(CFPropertyListRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyData: not enough space for the consumer count");
				theConsumerCountValue = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &theConsumerCount);
				FailWithAction(theConsumerCountValue == NULL, theAnswer = kAudioHardwareUnspecifiedError, Done, "AICameraAudioDriver_GetDevicePropertyData: unable to allocate the consumer count");
				*((CFPropertyListRef*)outData) = theConsumerCountValue;
				*outDataSize = sizeof(CFPropertyListRef);
			}
			break;

		case kAudioDevicePropertyDeviceCanBeDefaultDevice:
			//	This property returns whether or not the device wants to be able to be the
			//	default device for content. This is the device that iTunes and QuickTime
			//	will use to play their content on and FaceTime will use as it's microhphone.
			//	Nearly all devices should allow for this.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyDeviceCanBeDefaultDevice for the device");
			*((UInt32*)outData) = inAddress->mScope == kAudioObjectPropertyScopeInput ? 1 : 0;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
			//	This property returns whether or not the device wants to be the system
			//	default device. This is the device that is used to play interface sounds and
			//	other incidental or UI-related sounds on. Most devices should allow this
			//	although devices with lots of latency may not want to.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyDeviceCanBeDefaultSystemDevice for the device");
			*((UInt32*)outData) = 0;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyLatency:
			//	This property returns the presentation latency of the device. For this,
			//	device, the value is 0 due to the fact that it always vends silence.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyLatency for the device");
			*((UInt32*)outData) = 0;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyStreams:
			theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);
			switch(inAddress->mScope)
			{
				case kAudioObjectPropertyScopeGlobal:
					theNumberItemsToFetch = theNumberItemsToFetch > 2 ? 2 : theNumberItemsToFetch;
					if(theNumberItemsToFetch > 0) ((AudioObjectID*)outData)[0] = kObjectID_Stream_Input;
					if(theNumberItemsToFetch > 1) ((AudioObjectID*)outData)[1] = kObjectID_Stream_Output;
					break;
				case kAudioObjectPropertyScopeInput:
					theNumberItemsToFetch = theNumberItemsToFetch > 0 ? 1 : 0;
					if(theNumberItemsToFetch > 0) ((AudioObjectID*)outData)[0] = kObjectID_Stream_Input;
					break;
				case kAudioObjectPropertyScopeOutput:
					theNumberItemsToFetch = theNumberItemsToFetch > 0 ? 1 : 0;
					if(theNumberItemsToFetch > 0) ((AudioObjectID*)outData)[0] = kObjectID_Stream_Output;
					break;
				case kAudioObjectPropertyScopePlayThrough:
					theNumberItemsToFetch = 0;
					break;
				default:
					theNumberItemsToFetch = 0;
					theAnswer = kAudioHardwareUnknownPropertyError;
					break;
			}
			*outDataSize = theNumberItemsToFetch * sizeof(AudioObjectID);
			break;

		case kAudioObjectPropertyControlList:
			*outDataSize = 0;
			break;

		case kAudioDevicePropertySafetyOffset:
			//	This property returns the how close to now the HAL can read and write. For
			//	this, device, the value is 0 due to the fact that it always vends silence.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertySafetyOffset for the device");
			*((UInt32*)outData) = 0;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyNominalSampleRate:
			//	This property returns the nominal sample rate of the device. Note that we
			//	only need to take the state lock to get this value.
			FailWithAction(inDataSize < sizeof(Float64), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyNominalSampleRate for the device");
			pthread_mutex_lock(&gPlugIn_StateMutex);
			*((Float64*)outData) = gDevice_SampleRate;
			pthread_mutex_unlock(&gPlugIn_StateMutex);
			*outDataSize = sizeof(Float64);
			break;

		case kAudioDevicePropertyAvailableNominalSampleRates:
			//	This returns all nominal sample rates the device supports as an array of
			//	AudioValueRangeStructs. Note that for discrete sampler rates, the range
			//	will have the minimum value equal to the maximum value.

			//	Calculate the number of items that have been requested. Note that this
			//	number is allowed to be smaller than the actual size of the list. In such
			//	case, only that number of items will be returned
			theNumberItemsToFetch = inDataSize / sizeof(AudioValueRange);

			//	clamp it to the number of items we have
			if(theNumberItemsToFetch > 2)
			{
				theNumberItemsToFetch = 2;
			}

			//	fill out the return array
			if(theNumberItemsToFetch > 0)
			{
				((AudioValueRange*)outData)[0].mMinimum = 44100.0;
				((AudioValueRange*)outData)[0].mMaximum = 44100.0;
			}
			if(theNumberItemsToFetch > 1)
			{
				((AudioValueRange*)outData)[1].mMinimum = 48000.0;
				((AudioValueRange*)outData)[1].mMaximum = 48000.0;
			}

			//	report how much we wrote
			*outDataSize = theNumberItemsToFetch * sizeof(AudioValueRange);
			break;

		case kAudioDevicePropertyIsHidden:
			//	This returns whether or not the device is visible to clients.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyIsHidden for the device");
			*((UInt32*)outData) = 0;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioDevicePropertyPreferredChannelsForStereo:
			//	This property returns which two channesl to use as left/right for stereo
			//	data by default. Note that the channel numbers are 1-based.xz
			FailWithAction(inDataSize < (2 * sizeof(UInt32)), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyPreferredChannelsForStereo for the device");
			((UInt32*)outData)[0] = 1;
			((UInt32*)outData)[1] = 2;
			*outDataSize = 2 * sizeof(UInt32);
			break;

		case kAudioDevicePropertyPreferredChannelLayout:
			//	This property returns the default AudioChannelLayout to use for the device
			//	by default. For this device, we return a stereo ACL.
			{
				//	calcualte how big the
				UInt32 theACLSize = offsetof(AudioChannelLayout, mChannelDescriptions) + (2 * sizeof(AudioChannelDescription));
				FailWithAction(inDataSize < theACLSize, theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyPreferredChannelLayout for the device");
				((AudioChannelLayout*)outData)->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
				((AudioChannelLayout*)outData)->mChannelBitmap = 0;
				((AudioChannelLayout*)outData)->mNumberChannelDescriptions = 2;
				for(theItemIndex = 0; theItemIndex < 2; ++theItemIndex)
				{
					((AudioChannelLayout*)outData)->mChannelDescriptions[theItemIndex].mChannelLabel = kAudioChannelLabel_Left + theItemIndex;
					((AudioChannelLayout*)outData)->mChannelDescriptions[theItemIndex].mChannelFlags = 0;
					((AudioChannelLayout*)outData)->mChannelDescriptions[theItemIndex].mCoordinates[0] = 0;
					((AudioChannelLayout*)outData)->mChannelDescriptions[theItemIndex].mCoordinates[1] = 0;
					((AudioChannelLayout*)outData)->mChannelDescriptions[theItemIndex].mCoordinates[2] = 0;
				}
				*outDataSize = theACLSize;
			}
			break;

		case kAudioDevicePropertyZeroTimeStampPeriod:
			//	This property returns how many frames the HAL should expect to see between
			//	successive sample times in the zero time stamps this device provides.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyZeroTimeStampPeriod for the device");
			*((UInt32*)outData) = kDevice_RingBufferSize;
			*outDataSize = sizeof(UInt32);
			break;


		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_SetDevicePropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2])
{
	#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

	//	declare the local variables
	OSStatus theAnswer = 0;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_SetDevicePropertyData: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_SetDevicePropertyData: no address");
	FailWithAction(outNumberPropertiesChanged == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_SetDevicePropertyData: no place to return the number of properties that changed");
	FailWithAction(outChangedAddresses == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_SetDevicePropertyData: no place to return the properties that changed");
	FailWithAction(inObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_SetDevicePropertyData: not the device object");

	//	initialize the returned number of changed properties
	*outNumberPropertiesChanged = 0;

	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the AICameraAudioDriver_GetDevicePropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioDevicePropertyNominalSampleRate:
			//	Changing the sample rate needs to be handled via the
			//	RequestConfigChange/PerformConfigChange machinery.

			//	check the arguments
			FailWithAction(inDataSize != sizeof(Float64), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_SetDevicePropertyData: wrong size for the data for kAudioDevicePropertyNominalSampleRate");
			FailWithAction((*((const Float64*)inData) != 44100.0) && (*((const Float64*)inData) != 48000.0), theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_SetDevicePropertyData: unsupported value for kAudioDevicePropertyNominalSampleRate");

			AICameraAudioDriver_RequestSampleRate(*((const Float64*)inData));

			break;

		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

#pragma mark Stream Property Operations

static Boolean	AICameraAudioDriver_HasStreamProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
	//	This method returns whether or not the given object has the given property.

	#pragma unused(inClientProcessID)

	//	declare the local variables
	Boolean theAnswer = false;

	//	check the arguments
	FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "AICameraAudioDriver_HasStreamProperty: bad driver reference");
	FailIf(inAddress == NULL, Done, "AICameraAudioDriver_HasStreamProperty: no address");
	FailIf((inObjectID != kObjectID_Stream_Input) && (inObjectID != kObjectID_Stream_Output), Done, "AICameraAudioDriver_HasStreamProperty: not a stream object");

	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the AICameraAudioDriver_GetStreamPropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
		case kAudioObjectPropertyClass:
		case kAudioObjectPropertyOwner:
		case kAudioObjectPropertyOwnedObjects:
		case kAudioObjectPropertyName:
		case kAudioStreamPropertyIsActive:
		case kAudioStreamPropertyDirection:
		case kAudioStreamPropertyTerminalType:
		case kAudioStreamPropertyStartingChannel:
		case kAudioStreamPropertyLatency:
		case kAudioStreamPropertyVirtualFormat:
		case kAudioStreamPropertyPhysicalFormat:
		case kAudioStreamPropertyAvailableVirtualFormats:
		case kAudioStreamPropertyAvailablePhysicalFormats:
			theAnswer = true;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_IsStreamPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
	//	This method returns whether or not the given property on the object can have its value
	//	changed.

	#pragma unused(inClientProcessID)

	//	declare the local variables
	OSStatus theAnswer = 0;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_IsStreamPropertySettable: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_IsStreamPropertySettable: no address");
	FailWithAction(outIsSettable == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_IsStreamPropertySettable: no place to put the return value");
	FailWithAction((inObjectID != kObjectID_Stream_Input) && (inObjectID != kObjectID_Stream_Output), theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_IsStreamPropertySettable: not a stream object");

	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the AICameraAudioDriver_GetStreamPropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
		case kAudioObjectPropertyClass:
		case kAudioObjectPropertyOwner:
		case kAudioObjectPropertyOwnedObjects:
		case kAudioObjectPropertyName:
		case kAudioStreamPropertyDirection:
		case kAudioStreamPropertyTerminalType:
		case kAudioStreamPropertyStartingChannel:
		case kAudioStreamPropertyLatency:
		case kAudioStreamPropertyAvailableVirtualFormats:
		case kAudioStreamPropertyAvailablePhysicalFormats:
			*outIsSettable = false;
			break;

		case kAudioStreamPropertyIsActive:
		case kAudioStreamPropertyVirtualFormat:
		case kAudioStreamPropertyPhysicalFormat:
			*outIsSettable = true;
			break;

		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_GetStreamPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
	//	This method returns the byte size of the property's data.

	#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

	//	declare the local variables
	OSStatus theAnswer = 0;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_GetStreamPropertyDataSize: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetStreamPropertyDataSize: no address");
	FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetStreamPropertyDataSize: no place to put the return value");
	FailWithAction((inObjectID != kObjectID_Stream_Input) && (inObjectID != kObjectID_Stream_Output), theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_GetStreamPropertyDataSize: not a stream object");

	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the AICameraAudioDriver_GetStreamPropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
			*outDataSize = sizeof(AudioClassID);
			break;

		case kAudioObjectPropertyClass:
			*outDataSize = sizeof(AudioClassID);
			break;

		case kAudioObjectPropertyOwner:
			*outDataSize = sizeof(AudioObjectID);
			break;

		case kAudioObjectPropertyOwnedObjects:
			*outDataSize = 0 * sizeof(AudioObjectID);
			break;

		case kAudioObjectPropertyName:
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioStreamPropertyIsActive:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioStreamPropertyDirection:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioStreamPropertyTerminalType:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioStreamPropertyStartingChannel:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioStreamPropertyLatency:
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioStreamPropertyVirtualFormat:
		case kAudioStreamPropertyPhysicalFormat:
			*outDataSize = sizeof(AudioStreamBasicDescription);
			break;

		case kAudioStreamPropertyAvailableVirtualFormats:
		case kAudioStreamPropertyAvailablePhysicalFormats:
			*outDataSize = 2 * sizeof(AudioStreamRangedDescription);
			break;

		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_GetStreamPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
	#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

	//	declare the local variables
	OSStatus theAnswer = 0;
	UInt32 theNumberItemsToFetch;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_GetStreamPropertyData: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetStreamPropertyData: no address");
	FailWithAction(outDataSize == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetStreamPropertyData: no place to put the return value size");
	FailWithAction(outData == NULL && inDataSize > 0, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetStreamPropertyData: no place to put the return value");
	FailWithAction((inObjectID != kObjectID_Stream_Input) && (inObjectID != kObjectID_Stream_Output), theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_GetStreamPropertyData: not a stream object");

	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required.
	//
	//	Also, since most of the data that will get returned is static, there are few instances where
	//	it is necessary to lock the state mutex.
	switch(inAddress->mSelector)
	{
		case kAudioObjectPropertyBaseClass:
			//	The base class for kAudioStreamClassID is kAudioObjectClassID
			FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetStreamPropertyData: not enough space for the return value of kAudioObjectPropertyBaseClass for the stream");
			*((AudioClassID*)outData) = kAudioObjectClassID;
			*outDataSize = sizeof(AudioClassID);
			break;

		case kAudioObjectPropertyClass:
			//	The class is always kAudioStreamClassID for streams created by drivers
			FailWithAction(inDataSize < sizeof(AudioClassID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetStreamPropertyData: not enough space for the return value of kAudioObjectPropertyClass for the stream");
			*((AudioClassID*)outData) = kAudioStreamClassID;
			*outDataSize = sizeof(AudioClassID);
			break;

		case kAudioObjectPropertyOwner:
			//	The stream's owner is the device object
			FailWithAction(inDataSize < sizeof(AudioObjectID), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetStreamPropertyData: not enough space for the return value of kAudioObjectPropertyOwner for the stream");
			*((AudioObjectID*)outData) = kObjectID_Device;
			*outDataSize = sizeof(AudioObjectID);
			break;

		case kAudioObjectPropertyOwnedObjects:
			//	Streams do not own any objects
			*outDataSize = 0 * sizeof(AudioObjectID);
			break;

		case kAudioObjectPropertyName:
			//	This is the human readable name of the stream
			FailWithAction(inDataSize < sizeof(CFStringRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetStreamPropertyData: not enough space for the return value of kAudioObjectPropertyName for the stream");
			*((CFStringRef*)outData) = (inObjectID == kObjectID_Stream_Input) ? CFSTR("InputStreamName") : CFSTR("OutputStreamName");
			*outDataSize = sizeof(CFStringRef);
			break;

		case kAudioStreamPropertyIsActive:
			//	This property tells the device whether or not the given stream is going to
			//	be used for IO. Note that we need to take the state lock to examine this
			//	value.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetStreamPropertyData: not enough space for the return value of kAudioStreamPropertyIsActive for the stream");
			pthread_mutex_lock(&gPlugIn_StateMutex);
			*((UInt32*)outData) = (inObjectID == kObjectID_Stream_Input) ? gStream_Input_IsActive : gStream_Output_IsActive;
			pthread_mutex_unlock(&gPlugIn_StateMutex);
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioStreamPropertyDirection:
			//	This returns whether the stream is an input stream or an output stream.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetStreamPropertyData: not enough space for the return value of kAudioStreamPropertyDirection for the stream");
			*((UInt32*)outData) = (inObjectID == kObjectID_Stream_Input) ? 1 : 0;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioStreamPropertyTerminalType:
			//	This returns a value that indicates what is at the other end of the stream
			//	such as a speaker or headphones, or a microphone. Values for this property
			//	are defined in <CoreAudio/AudioHardwareBase.h>
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetStreamPropertyData: not enough space for the return value of kAudioStreamPropertyTerminalType for the stream");
			*((UInt32*)outData) = (inObjectID == kObjectID_Stream_Input) ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioStreamPropertyStartingChannel:
			//	This property returns the absolute channel number for the first channel in
			//	the stream. For exmaple, if a device has two output streams with two
			//	channels each, then the starting channel number for the first stream is 1
			//	and ths starting channel number fo the second stream is 3.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetStreamPropertyData: not enough space for the return value of kAudioStreamPropertyStartingChannel for the stream");
			*((UInt32*)outData) = 1;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioStreamPropertyLatency:
			//	This property returns any additonal presentation latency the stream has.
			FailWithAction(inDataSize < sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetStreamPropertyData: not enough space for the return value of kAudioStreamPropertyStartingChannel for the stream");
			*((UInt32*)outData) = 0;
			*outDataSize = sizeof(UInt32);
			break;

		case kAudioStreamPropertyVirtualFormat:
		case kAudioStreamPropertyPhysicalFormat:
			//	This returns the current format of the stream in an
			//	AudioStreamBasicDescription. Note that we need to hold the state lock to get
			//	this value.
			//	Note that for devices that don't override the mix operation, the virtual
			//	format has to be the same as the physical format.
			FailWithAction(inDataSize < sizeof(AudioStreamBasicDescription), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_GetStreamPropertyData: not enough space for the return value of kAudioStreamPropertyVirtualFormat for the stream");
			pthread_mutex_lock(&gPlugIn_StateMutex);
			((AudioStreamBasicDescription*)outData)->mSampleRate = gDevice_SampleRate;
			((AudioStreamBasicDescription*)outData)->mFormatID = kAudioFormatLinearPCM;
			((AudioStreamBasicDescription*)outData)->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
			((AudioStreamBasicDescription*)outData)->mBytesPerPacket = 8;
			((AudioStreamBasicDescription*)outData)->mFramesPerPacket = 1;
			((AudioStreamBasicDescription*)outData)->mBytesPerFrame = 8;
			((AudioStreamBasicDescription*)outData)->mChannelsPerFrame = 2;
			((AudioStreamBasicDescription*)outData)->mBitsPerChannel = 32;
			((AudioStreamBasicDescription*)outData)->mReserved = 0;
			pthread_mutex_unlock(&gPlugIn_StateMutex);
			*outDataSize = sizeof(AudioStreamBasicDescription);
			break;

		case kAudioStreamPropertyAvailableVirtualFormats:
		case kAudioStreamPropertyAvailablePhysicalFormats:
			//	This returns an array of AudioStreamRangedDescriptions that describe what
			//	formats are supported.

			//	Calculate the number of items that have been requested. Note that this
			//	number is allowed to be smaller than the actual size of the list. In such
			//	case, only that number of items will be returned
			theNumberItemsToFetch = inDataSize / sizeof(AudioStreamRangedDescription);

			//	clamp it to the number of items we have
			if(theNumberItemsToFetch > 2)
			{
				theNumberItemsToFetch = 2;
			}

			//	fill out the return array
			if(theNumberItemsToFetch > 0)
			{
				((AudioStreamRangedDescription*)outData)[0].mFormat.mSampleRate = 44100.0;
				((AudioStreamRangedDescription*)outData)[0].mFormat.mFormatID = kAudioFormatLinearPCM;
				((AudioStreamRangedDescription*)outData)[0].mFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
				((AudioStreamRangedDescription*)outData)[0].mFormat.mBytesPerPacket = 8;
				((AudioStreamRangedDescription*)outData)[0].mFormat.mFramesPerPacket = 1;
				((AudioStreamRangedDescription*)outData)[0].mFormat.mBytesPerFrame = 8;
				((AudioStreamRangedDescription*)outData)[0].mFormat.mChannelsPerFrame = 2;
				((AudioStreamRangedDescription*)outData)[0].mFormat.mBitsPerChannel = 32;
				((AudioStreamRangedDescription*)outData)[0].mFormat.mReserved = 0;
				((AudioStreamRangedDescription*)outData)[0].mSampleRateRange.mMinimum = 44100.0;
				((AudioStreamRangedDescription*)outData)[0].mSampleRateRange.mMaximum = 44100.0;
			}
			if(theNumberItemsToFetch > 1)
			{
				((AudioStreamRangedDescription*)outData)[1].mFormat.mSampleRate = 48000.0;
				((AudioStreamRangedDescription*)outData)[1].mFormat.mFormatID = kAudioFormatLinearPCM;
				((AudioStreamRangedDescription*)outData)[1].mFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
				((AudioStreamRangedDescription*)outData)[1].mFormat.mBytesPerPacket = 8;
				((AudioStreamRangedDescription*)outData)[1].mFormat.mFramesPerPacket = 1;
				((AudioStreamRangedDescription*)outData)[1].mFormat.mBytesPerFrame = 8;
				((AudioStreamRangedDescription*)outData)[1].mFormat.mChannelsPerFrame = 2;
				((AudioStreamRangedDescription*)outData)[1].mFormat.mBitsPerChannel = 32;
				((AudioStreamRangedDescription*)outData)[1].mFormat.mReserved = 0;
				((AudioStreamRangedDescription*)outData)[1].mSampleRateRange.mMinimum = 48000.0;
				((AudioStreamRangedDescription*)outData)[1].mSampleRateRange.mMaximum = 48000.0;
			}

			//	report how much we wrote
			*outDataSize = theNumberItemsToFetch * sizeof(AudioStreamRangedDescription);
			break;

		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_SetStreamPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData, UInt32* outNumberPropertiesChanged, AudioObjectPropertyAddress outChangedAddresses[2])
{
	#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

	//	declare the local variables
	OSStatus theAnswer = 0;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_SetStreamPropertyData: bad driver reference");
	FailWithAction(inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_SetStreamPropertyData: no address");
	FailWithAction(outNumberPropertiesChanged == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_SetStreamPropertyData: no place to return the number of properties that changed");
	FailWithAction(outChangedAddresses == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_SetStreamPropertyData: no place to return the properties that changed");
	FailWithAction((inObjectID != kObjectID_Stream_Input) && (inObjectID != kObjectID_Stream_Output), theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_SetStreamPropertyData: not a stream object");

	//	initialize the returned number of changed properties
	*outNumberPropertiesChanged = 0;

	//	Note that for each object, this driver implements all the required properties plus a few
	//	extras that are useful but not required. There is more detailed commentary about each
	//	property in the AICameraAudioDriver_GetStreamPropertyData() method.
	switch(inAddress->mSelector)
	{
		case kAudioStreamPropertyIsActive:
			//	Changing the active state of a stream doesn't affect IO or change the structure
			//	so we can just save the state and send the notification.
			FailWithAction(inDataSize != sizeof(UInt32), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_SetStreamPropertyData: wrong size for the data for kAudioDevicePropertyNominalSampleRate");
			pthread_mutex_lock(&gPlugIn_StateMutex);
			if(inObjectID == kObjectID_Stream_Input)
			{
				if(gStream_Input_IsActive != (*((const UInt32*)inData) != 0))
				{
					gStream_Input_IsActive = *((const UInt32*)inData) != 0;
					*outNumberPropertiesChanged = 1;
					outChangedAddresses[0].mSelector = kAudioStreamPropertyIsActive;
					outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
					outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
				}
			}
			else
			{
				if(gStream_Output_IsActive != (*((const UInt32*)inData) != 0))
				{
					gStream_Output_IsActive = *((const UInt32*)inData) != 0;
					*outNumberPropertiesChanged = 1;
					outChangedAddresses[0].mSelector = kAudioStreamPropertyIsActive;
					outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
					outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
				}
			}
			pthread_mutex_unlock(&gPlugIn_StateMutex);
			break;

		case kAudioStreamPropertyVirtualFormat:
		case kAudioStreamPropertyPhysicalFormat:
			//	Changing the stream format needs to be handled via the
			//	RequestConfigChange/PerformConfigChange machinery. Note that because this
			//	device only supports 2 channel 32 bit float data, the only thing that can
			//	change is the sample rate.
			FailWithAction(inDataSize != sizeof(AudioStreamBasicDescription), theAnswer = kAudioHardwareBadPropertySizeError, Done, "AICameraAudioDriver_SetStreamPropertyData: wrong size for the data for kAudioStreamPropertyPhysicalFormat");
			FailWithAction(((const AudioStreamBasicDescription*)inData)->mFormatID != kAudioFormatLinearPCM, theAnswer = kAudioDeviceUnsupportedFormatError, Done, "AICameraAudioDriver_SetStreamPropertyData: unsupported format ID for kAudioStreamPropertyPhysicalFormat");
			FailWithAction(((const AudioStreamBasicDescription*)inData)->mFormatFlags != (kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked), theAnswer = kAudioDeviceUnsupportedFormatError, Done, "AICameraAudioDriver_SetStreamPropertyData: unsupported format flags for kAudioStreamPropertyPhysicalFormat");
			FailWithAction(((const AudioStreamBasicDescription*)inData)->mBytesPerPacket != 8, theAnswer = kAudioDeviceUnsupportedFormatError, Done, "AICameraAudioDriver_SetStreamPropertyData: unsupported bytes per packet for kAudioStreamPropertyPhysicalFormat");
			FailWithAction(((const AudioStreamBasicDescription*)inData)->mFramesPerPacket != 1, theAnswer = kAudioDeviceUnsupportedFormatError, Done, "AICameraAudioDriver_SetStreamPropertyData: unsupported frames per packet for kAudioStreamPropertyPhysicalFormat");
			FailWithAction(((const AudioStreamBasicDescription*)inData)->mBytesPerFrame != 8, theAnswer = kAudioDeviceUnsupportedFormatError, Done, "AICameraAudioDriver_SetStreamPropertyData: unsupported bytes per frame for kAudioStreamPropertyPhysicalFormat");
			FailWithAction(((const AudioStreamBasicDescription*)inData)->mChannelsPerFrame != 2, theAnswer = kAudioDeviceUnsupportedFormatError, Done, "AICameraAudioDriver_SetStreamPropertyData: unsupported channels per frame for kAudioStreamPropertyPhysicalFormat");
			FailWithAction(((const AudioStreamBasicDescription*)inData)->mBitsPerChannel != 32, theAnswer = kAudioDeviceUnsupportedFormatError, Done, "AICameraAudioDriver_SetStreamPropertyData: unsupported bits per channel for kAudioStreamPropertyPhysicalFormat");
			FailWithAction((((const AudioStreamBasicDescription*)inData)->mSampleRate != 44100.0) && (((const AudioStreamBasicDescription*)inData)->mSampleRate != 48000.0), theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_SetStreamPropertyData: unsupported sample rate for kAudioStreamPropertyPhysicalFormat");

			AICameraAudioDriver_RequestSampleRate(((const AudioStreamBasicDescription*)inData)->mSampleRate);

			break;

		default:
			theAnswer = kAudioHardwareUnknownPropertyError;
			break;
	};

Done:
	return theAnswer;
}

#pragma mark IO Operations

static OSStatus	AICameraAudioDriver_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
	#pragma unused(inClientID)
	//	This call tells the device that IO is starting for the given client. When this routine
	//	returns, the device's clock is running and it is ready to have data read/written. It is
	//	important to note that multiple clients can have IO running on the device at the same time.
	//	So, work only needs to be done when the first client starts. All subsequent starts simply
	//	increment the counter.

	//	declare the local variables
	OSStatus theAnswer = 0;
	Boolean didStart = false;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_StartIO: bad driver reference");
	FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_StartIO: bad device ID");

	//	we need to hold the state lock
	pthread_mutex_lock(&gPlugIn_StateMutex);

	//	figure out what we need to do
	if(gDevice_IOIsRunning == UINT64_MAX)
	{
		//	overflowing is an error
		theAnswer = kAudioHardwareIllegalOperationError;
	}
	else if(gDevice_IOIsRunning == 0)
	{
		//	Anchor a fresh virtual-device timeline and discard samples from the prior run.
		gDevice_IOIsRunning = 1;
		didStart = true;
		pthread_mutex_lock(&gDevice_IOMutex);
		gDevice_NumberTimeStamps = 0;
		gDevice_ZeroTimeStampSeed = gDevice_ZeroTimeStampSeed == UINT64_MAX ? 1 : gDevice_ZeroTimeStampSeed + 1;
		gDevice_AnchorSampleTime = 0;
		gDevice_AnchorHostTime = mach_absolute_time();
		pthread_mutex_unlock(&gDevice_IOMutex);
		for(UInt32 theFrameIndex = 0; theFrameIndex < kDevice_RingBufferSize; ++theFrameIndex)
		{
			atomic_store_explicit(&gDevice_LoopbackFrameTags[theFrameIndex], UINT64_MAX, memory_order_relaxed);
			for(UInt32 theChannel = 0; theChannel < kDevice_ChannelCount; ++theChannel)
			{
				atomic_store_explicit(
					&gDevice_LoopbackSampleBits[(theFrameIndex * kDevice_ChannelCount) + theChannel],
					0,
					memory_order_relaxed);
			}
		}
		atomic_store_explicit(&gDevice_FirstOutputFrame, UINT64_MAX, memory_order_relaxed);
		atomic_store_explicit(&gDevice_LastOutputEndFrame, 0, memory_order_release);
	}
	else
	{
		//	IO is already running, so just bump the counter
		++gDevice_IOIsRunning;
	}
	//	unlock the state lock before notifying the host.
	pthread_mutex_unlock(&gPlugIn_StateMutex);
	if(didStart && gPlugIn_Host != NULL)
	{
		AudioObjectPropertyAddress theAddress = { kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
		gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Device, 1, &theAddress);
	}

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
	//	This call tells the device that the client has stopped IO. The driver can stop the hardware
	//	once all clients have stopped.

	//	declare the local variables
	OSStatus theAnswer = 0;
	Boolean didStop = false;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_StopIO: bad driver reference");
	FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_StopIO: bad device ID");

	//	we need to hold the state lock
	pthread_mutex_lock(&gPlugIn_StateMutex);

	//	figure out what we need to do
	if(gDevice_IOIsRunning == 0)
	{
		//	underflowing is an error
		theAnswer = kAudioHardwareIllegalOperationError;
	}
	else if(gDevice_IOIsRunning == 1)
	{
		//	We need to stop the hardware, which in this case means that there's nothing to do.
		gDevice_IOIsRunning = 0;
		didStop = true;
	}
	else
	{
		//	IO is still running, so just bump the counter
		--gDevice_IOIsRunning;
	}
	//	unlock the state lock before notifying the host.
	pthread_mutex_unlock(&gPlugIn_StateMutex);
	if(didStop && gPlugIn_Host != NULL)
	{
		AudioObjectPropertyAddress theAddress = { kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
		gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Device, 1, &theAddress);
	}
	if(theAnswer == noErr)
	{
		AICameraAudioDriver_ClearInputConsumer(inClientID);
	}

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_GetZeroTimeStamp(
	AudioServerPlugInDriverRef inDriver,
	AudioObjectID inDeviceObjectID,
	UInt32 inClientID,
	Float64* outSampleTime,
	UInt64* outHostTime,
	UInt64* outSeed)
{
	#pragma unused(inClientID)
	OSStatus theAnswer = 0;
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_GetZeroTimeStamp: bad driver reference");
	FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_GetZeroTimeStamp: bad device ID");
	FailWithAction(outSampleTime == NULL || outHostTime == NULL || outSeed == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_GetZeroTimeStamp: missing output");

	pthread_mutex_lock(&gDevice_IOMutex);
	UInt64 theCurrentHostTime = mach_absolute_time();
	Float64 theHostTicksPerRingBuffer = gDevice_HostTicksPerFrame * (Float64)kDevice_RingBufferSize;
	if(!isfinite(theHostTicksPerRingBuffer) || theHostTicksPerRingBuffer <= 0.0)
	{
		theAnswer = kAudioHardwareIllegalOperationError;
		pthread_mutex_unlock(&gDevice_IOMutex);
		goto Done;
	}

	if(theCurrentHostTime >= gDevice_AnchorHostTime)
	{
		Float64 theElapsedTicks = (Float64)(theCurrentHostTime - gDevice_AnchorHostTime);
		Float64 theCompletedPeriods = floor(theElapsedTicks / theHostTicksPerRingBuffer);
		if(isfinite(theCompletedPeriods) && theCompletedPeriods >= 0.0 &&
			theCompletedPeriods < (Float64)UINT64_MAX)
		{
			UInt64 theAvailableTimeStamps = (UInt64)theCompletedPeriods;
			if(theAvailableTimeStamps > gDevice_NumberTimeStamps)
			{
				gDevice_NumberTimeStamps = theAvailableTimeStamps;
			}
		}
	}

	Float64 theHostTickOffset = (Float64)gDevice_NumberTimeStamps * theHostTicksPerRingBuffer;
	if(!isfinite(theHostTickOffset) || theHostTickOffset >= (Float64)(UINT64_MAX - gDevice_AnchorHostTime))
	{
		theAnswer = kAudioHardwareIllegalOperationError;
		pthread_mutex_unlock(&gDevice_IOMutex);
		goto Done;
	}
	*outSampleTime = (Float64)gDevice_NumberTimeStamps * (Float64)kDevice_RingBufferSize;
	*outHostTime = gDevice_AnchorHostTime + (UInt64)theHostTickOffset;
	*outSeed = gDevice_ZeroTimeStampSeed;
	pthread_mutex_unlock(&gDevice_IOMutex);

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace)
{
	//	This method returns whether or not the device will do a given IO operation. For this device,
	//	we only support reading input data and writing output data.

	#pragma unused(inClientID)

	//	declare the local variables
	OSStatus theAnswer = 0;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_WillDoIOOperation: bad driver reference");
	FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_WillDoIOOperation: bad device ID");

	//	figure out if we support the operation
	bool willDo = false;
	bool willDoInPlace = true;
	switch(inOperationID)
	{
		case kAudioServerPlugInIOOperationReadInput:
			willDo = true;
			willDoInPlace = true;
			break;

		case kAudioServerPlugInIOOperationWriteMix:
			willDo = true;
			willDoInPlace = true;
			break;

	};

	//	fill out the return values
	if(outWillDo != NULL)
	{
		*outWillDo = willDo;
	}
	if(outWillDoInPlace != NULL)
	{
		*outWillDoInPlace = willDoInPlace;
	}

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
	//	This is called at the beginning of an IO operation. This device doesn't do anything, so just
	//	check the arguments and return.

	#pragma unused(inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo)

	//	declare the local variables
	OSStatus theAnswer = 0;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_BeginIOOperation: bad driver reference");
	FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_BeginIOOperation: bad device ID");

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer)
{
	//	The HAL calls this method on a real-time thread. Address the preallocated ring directly by
	//	the device sample timeline so reads are non-destructive and multiple input clients receive
	//	the same samples. Never allocate, lock, log, or perform IPC in this method.

	#pragma unused(ioSecondaryBuffer)

	OSStatus theAnswer = 0;
	const AudioTimeStamp* theTimeStamp = NULL;
	UInt64 theFrame = 0;
	UInt64 theRequestedEndFrame = 0;

	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_DoIOOperation: bad driver reference");
	FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_DoIOOperation: bad device ID");
	FailWithAction((inStreamObjectID != kObjectID_Stream_Input) && (inStreamObjectID != kObjectID_Stream_Output), theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_DoIOOperation: bad stream ID");
	FailWithAction(inIOCycleInfo == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_DoIOOperation: no IO cycle info");
	FailWithAction(ioMainBuffer == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "AICameraAudioDriver_DoIOOperation: no main buffer");

	if((inOperationID != kAudioServerPlugInIOOperationReadInput) &&
		(inOperationID != kAudioServerPlugInIOOperationWriteMix))
	{
		goto Done;
	}

	if(inIOBufferFrameSize > kDevice_RingBufferSize)
	{
		// The caller's buffer extent is not trustworthy for an invalid frame count.
		theAnswer = kAudioHardwareBadPropertySizeError;
		goto Done;
	}

	if(inOperationID == kAudioServerPlugInIOOperationReadInput)
	{
		FailWithAction(inStreamObjectID != kObjectID_Stream_Input, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_DoIOOperation: ReadInput on a non-input stream");
		theTimeStamp = &inIOCycleInfo->mInputTime;
	}
	else
	{
		FailWithAction(inStreamObjectID != kObjectID_Stream_Output, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_DoIOOperation: WriteMix on a non-output stream");
		theTimeStamp = &inIOCycleInfo->mOutputTime;
	}

	Float64 theSampleTime = theTimeStamp->mSampleTime;
	if(((theTimeStamp->mFlags & kAudioTimeStampSampleTimeValid) == 0) ||
		!isfinite(theSampleTime) || theSampleTime < 0.0 || floor(theSampleTime) != theSampleTime ||
		theSampleTime >= 0x1p64)
	{
		if(inOperationID == kAudioServerPlugInIOOperationReadInput)
		{
			memset(ioMainBuffer, 0, (size_t)inIOBufferFrameSize * kDevice_ChannelCount * sizeof(Float32));
		}
		theAnswer = kAudioHardwareIllegalOperationError;
		goto Done;
	}

	theFrame = (UInt64)theSampleTime;
	if(UINT64_MAX - theFrame < inIOBufferFrameSize)
	{
		if(inOperationID == kAudioServerPlugInIOOperationReadInput)
		{
			memset(ioMainBuffer, 0, (size_t)inIOBufferFrameSize * kDevice_ChannelCount * sizeof(Float32));
		}
		theAnswer = kAudioHardwareIllegalOperationError;
		goto Done;
	}
	theRequestedEndFrame = theFrame + inIOBufferFrameSize;

	if(inOperationID == kAudioServerPlugInIOOperationReadInput)
	{
		AICameraAudioDriver_MarkInputConsumer(inClientID);
	}

	if(inOperationID == kAudioServerPlugInIOOperationWriteMix)
	{
		UInt64 thePreviousEndFrame = atomic_load_explicit(&gDevice_LastOutputEndFrame, memory_order_acquire);
		if((thePreviousEndFrame == 0) || (thePreviousEndFrame != theFrame))
		{
			//	A writer started or its timeline jumped. Do not make stale gap contents readable.
			atomic_store_explicit(&gDevice_LastOutputEndFrame, 0, memory_order_release);
			atomic_store_explicit(&gDevice_FirstOutputFrame, theFrame, memory_order_relaxed);
		}

		const Float32* theInputSamples = (const Float32*)ioMainBuffer;
		for(UInt32 theBufferFrame = 0; theBufferFrame < inIOBufferFrameSize; ++theBufferFrame)
		{
			UInt64 theAbsoluteFrame = theFrame + theBufferFrame;
			UInt32 theSlot = (UInt32)(theAbsoluteFrame % kDevice_RingBufferSize);
			// Invalidate before changing sample bits so a reader never accepts a partial overwrite.
			atomic_store_explicit(&gDevice_LoopbackFrameTags[theSlot], UINT64_MAX, memory_order_release);
			for(UInt32 theChannel = 0; theChannel < kDevice_ChannelCount; ++theChannel)
			{
				UInt32 theBits = 0;
				memcpy(&theBits,
					theInputSamples + (theBufferFrame * kDevice_ChannelCount) + theChannel,
					sizeof(theBits));
				atomic_store_explicit(
					&gDevice_LoopbackSampleBits[(theSlot * kDevice_ChannelCount) + theChannel],
					theBits,
					memory_order_release);
			}
			atomic_store_explicit(&gDevice_LoopbackFrameTags[theSlot], theAbsoluteFrame, memory_order_release);
		}

		//	The release store publishes the completed frame range.
		atomic_store_explicit(&gDevice_LastOutputEndFrame, theRequestedEndFrame, memory_order_release);
	}
	else
	{
		UInt64 theLastOutputEndFrame = atomic_load_explicit(&gDevice_LastOutputEndFrame, memory_order_acquire);
		UInt64 theFirstOutputFrame = atomic_load_explicit(&gDevice_FirstOutputFrame, memory_order_acquire);
		Boolean hasCompleteRange =
			(theFirstOutputFrame != UINT64_MAX) &&
			(theFrame >= theFirstOutputFrame) &&
			(theLastOutputEndFrame >= theRequestedEndFrame) &&
			((theLastOutputEndFrame - theFrame) <= kDevice_RingBufferSize);

		if(!hasCompleteRange)
		{
			memset(ioMainBuffer, 0, (size_t)inIOBufferFrameSize * kDevice_ChannelCount * sizeof(Float32));
		}
		else
		{
			Float32* theOutputSamples = (Float32*)ioMainBuffer;
			for(UInt32 theBufferFrame = 0; theBufferFrame < inIOBufferFrameSize; ++theBufferFrame)
			{
				UInt64 theAbsoluteFrame = theFrame + theBufferFrame;
				UInt32 theSlot = (UInt32)(theAbsoluteFrame % kDevice_RingBufferSize);
				UInt64 theTagBefore = atomic_load_explicit(&gDevice_LoopbackFrameTags[theSlot], memory_order_acquire);
				UInt32 theBits[kDevice_ChannelCount] = { 0 };
				if(theTagBefore == theAbsoluteFrame)
				{
					for(UInt32 theChannel = 0; theChannel < kDevice_ChannelCount; ++theChannel)
					{
						theBits[theChannel] = atomic_load_explicit(
							&gDevice_LoopbackSampleBits[(theSlot * kDevice_ChannelCount) + theChannel],
							memory_order_acquire);
					}
				}
				UInt64 theTagAfter = atomic_load_explicit(&gDevice_LoopbackFrameTags[theSlot], memory_order_acquire);
				for(UInt32 theChannel = 0; theChannel < kDevice_ChannelCount; ++theChannel)
				{
					Float32 theSample = 0.0f;
					if((theTagBefore == theAbsoluteFrame) && (theTagAfter == theAbsoluteFrame))
					{
						memcpy(&theSample, &theBits[theChannel], sizeof(theSample));
					}
					theOutputSamples[(theBufferFrame * kDevice_ChannelCount) + theChannel] = theSample;
				}
			}
		}
	}

Done:
	return theAnswer;
}

static OSStatus	AICameraAudioDriver_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
	//	This is called at the end of an IO operation. This device doesn't do anything, so just check
	//	the arguments and return.

	#pragma unused(inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo)

	//	declare the local variables
	OSStatus theAnswer = 0;

	//	check the arguments
	FailWithAction(inDriver != gAudioServerPlugInDriverRef, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_EndIOOperation: bad driver reference");
	FailWithAction(inDeviceObjectID != kObjectID_Device, theAnswer = kAudioHardwareBadObjectError, Done, "AICameraAudioDriver_EndIOOperation: bad device ID");

Done:
	return theAnswer;
}
