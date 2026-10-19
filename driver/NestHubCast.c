// "Nest Hub (Cast)" virtual output device for nestcast.
// A loopback HAL plug-in derived from BlackHole (GPL-3.0, see LICENSE.BlackHole):
// apps play into it, nestcast reads its input side and casts to the Hub.
// It reports ~360 ms output latency (the measured Mac->Hub delay) so video
// players stay lip-synced. Not affiliated with Existential Audio.
#define kDriver_Name                     "Nest Hub (Cast)"
#define kPlugIn_BundleID                 "local.nestcast.driver"
#define kPlugIn_Icon                     ""
#define kHas_Driver_Name_Format          false
#define kDevice_Name                     "Nest Hub (Cast)"
#define kDevice2_Name                    "Nest Hub (Cast) Mirror"
#define kManufacturer_Name               "nestcast (local)"
#define kNumber_Of_Channels              2
#define kSampleRates                     48000
#define kLatency_Frame_Size              0
#ifndef kReported_Output_Latency_Frames
#define kReported_Output_Latency_Frames  17280   // 360 ms @ 48 kHz
#endif
#include "NestHubCast_impl.c"
