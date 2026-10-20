// Finds a Cast receiver by its friendly name (the "fn" TXT field, e.g. "Living Room")
// using the system mDNS responder. Called on every (re)connect, so a Hub that
// changed its IP address (DHCP, reboot) is found again.

#ifndef NESTCAST_DISCOVERY_H_
#define NESTCAST_DISCOVERY_H_

#include <chrono>
#include <optional>
#include <string>
#include <vector>

namespace nestcast {

struct CastDevice {
  std::string friendly_name;
  std::string model;
  std::string host;     // e.g. fuchsia-xxxx.local.
  std::string address;  // IPv4 dotted quad.
  int port = 0;
  std::string id;  // Unique Cast device ID (the "id" TXT field, 32 hex chars).
};

// Blocks for up to `timeout`. Returns the device whose unique Cast ID equals
// `id_or_name`, or else whose friendly name does. Friendly names are not
// unique (anyone on the network can name a device the same), so callers
// should store and look up the ID.
std::optional<CastDevice> FindCastDevice(const std::string& id_or_name,
                                         std::chrono::milliseconds timeout);

// Lists all Cast devices found within `timeout`.
std::vector<CastDevice> ListCastDevices(std::chrono::milliseconds timeout);

}  // namespace nestcast

#endif  // NESTCAST_DISCOVERY_H_
