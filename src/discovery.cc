#include "nestcast/discovery.h"

#include <arpa/inet.h>
#include <dns_sd.h>
#include <netinet/in.h>
#include <sys/select.h>

#include <vector>

namespace nestcast {
namespace {

using Clock = std::chrono::steady_clock;

struct Pending {
  std::string service_name;
  std::string domain;
};

struct State {
  std::string wanted;
  std::vector<Pending> found;
  // Resolve result for the current candidate.
  bool resolved = false;
  std::string fn, md, host;
  int port = 0;
  // Address result.
  bool have_addr = false;
  std::string addr;
};

std::string TxtValue(const unsigned char* txt, uint16_t len, const char* key) {
  uint8_t vlen = 0;
  const void* v = TXTRecordGetValuePtr(len, txt, key, &vlen);
  return v ? std::string(static_cast<const char*>(v), vlen) : std::string();
}

void BrowseCallback(DNSServiceRef, DNSServiceFlags flags, uint32_t,
                    DNSServiceErrorType err, const char* name, const char*,
                    const char* domain, void* ctx) {
  if (err != kDNSServiceErr_NoError || !(flags & kDNSServiceFlagsAdd)) {
    return;
  }
  static_cast<State*>(ctx)->found.push_back({name, domain});
}

void ResolveCallback(DNSServiceRef, DNSServiceFlags, uint32_t,
                     DNSServiceErrorType err, const char*,
                     const char* host, uint16_t port_be, uint16_t txt_len,
                     const unsigned char* txt, void* ctx) {
  auto* s = static_cast<State*>(ctx);
  if (err != kDNSServiceErr_NoError) {
    return;
  }
  s->resolved = true;
  s->host = host;
  s->port = ntohs(port_be);
  s->fn = TxtValue(txt, txt_len, "fn");
  s->md = TxtValue(txt, txt_len, "md");
}

// Only private/link-local IPv4 is a plausible LAN Cast device. (Some ISP
// resolvers answer unicast queries for unknown ".local" names with a public
// "search page" address, which must never be used.)
bool IsLanAddress(in_addr a) {
  const uint32_t h = ntohl(a.s_addr);
  return (h >> 24) == 10 || (h >> 20) == ((172u << 4) | 1) ||
         (h >> 16) == ((192u << 8) | 168) || (h >> 16) == ((169u << 8) | 254);
}

void AddrCallback(DNSServiceRef, DNSServiceFlags, uint32_t interface_index,
                  DNSServiceErrorType err, const char*,
                  const struct sockaddr* addr, uint32_t, void* ctx) {
  auto* s = static_cast<State*>(ctx);
  if (err != kDNSServiceErr_NoError || !addr || addr->sa_family != AF_INET) {
    return;
  }
  char buf[INET_ADDRSTRLEN];
  const auto* in = reinterpret_cast<const sockaddr_in*>(addr);
  // interface_index 0 means the answer came from unicast DNS, not mDNS.
  if (interface_index == 0 || !IsLanAddress(in->sin_addr)) {
    return;
  }
  if (inet_ntop(AF_INET, &in->sin_addr, buf, sizeof(buf))) {
    s->addr = buf;
    s->have_addr = true;
  }
}

// Processes events on `ref` until `done()` or `deadline`.
template <typename Done>
bool Pump(DNSServiceRef ref, Clock::time_point deadline, Done done) {
  const int fd = DNSServiceRefSockFD(ref);
  while (!done()) {
    const auto left = deadline - Clock::now();
    if (left <= Clock::duration::zero()) {
      return false;
    }
    const auto us =
        std::chrono::duration_cast<std::chrono::microseconds>(left).count();
    timeval tv{static_cast<time_t>(us / 1000000),
               static_cast<suseconds_t>(us % 1000000)};
    fd_set fds;
    FD_ZERO(&fds);
    FD_SET(fd, &fds);
    const int r = select(fd + 1, &fds, nullptr, nullptr, &tv);
    if (r > 0 && DNSServiceProcessResult(ref) != kDNSServiceErr_NoError) {
      return false;
    }
  }
  return true;
}

}  // namespace

namespace {
std::optional<CastDevice> Browse(const std::string& name,
                                 std::chrono::milliseconds timeout,
                                 bool list_all,
                                 std::vector<CastDevice>* all) {
  const auto deadline = Clock::now() + timeout;
  State s;
  s.wanted = name;
  DNSServiceRef browse = nullptr;
  if (DNSServiceBrowse(&browse, 0, kDNSServiceInterfaceIndexAny,
                       "_googlecast._tcp", nullptr, BrowseCallback,
                       &s) != kDNSServiceErr_NoError) {
    return std::nullopt;
  }
  size_t checked = 0;
  std::optional<CastDevice> result;
  while (!result && Clock::now() < deadline) {
    // Wait for new browse results (or a short slice of time).
    Pump(browse, std::min(deadline, Clock::now() + std::chrono::milliseconds(300)),
         [&] { return s.found.size() > checked; });
    for (; checked < s.found.size() && !result; ++checked) {
      const Pending& p = s.found[checked];
      s.resolved = false;
      DNSServiceRef resolve = nullptr;
      if (DNSServiceResolve(&resolve, 0, kDNSServiceInterfaceIndexAny,
                            p.service_name.c_str(), "_googlecast._tcp",
                            p.domain.c_str(), ResolveCallback,
                            &s) != kDNSServiceErr_NoError) {
        continue;
      }
      Pump(resolve, std::min(deadline, Clock::now() + std::chrono::seconds(2)),
           [&] { return s.resolved; });
      DNSServiceRefDeallocate(resolve);
      const bool match = name.empty()
                             ? s.md.find("Nest Hub") != std::string::npos
                             : s.fn == name;
      if (!s.resolved || (!list_all && !match)) {
        continue;
      }
      s.have_addr = false;
      DNSServiceRef addr = nullptr;
      if (DNSServiceGetAddrInfo(&addr, kDNSServiceFlagsForceMulticast,
                                kDNSServiceInterfaceIndexAny,
                                kDNSServiceProtocol_IPv4, s.host.c_str(),
                                AddrCallback, &s) != kDNSServiceErr_NoError) {
        continue;
      }
      Pump(addr, std::min(deadline, Clock::now() + std::chrono::seconds(2)),
           [&] { return s.have_addr; });
      DNSServiceRefDeallocate(addr);
      if (s.have_addr) {
        if (list_all) {
          bool seen = false;
          for (const CastDevice& d : *all) {
            seen = seen || d.friendly_name == s.fn;
          }
          if (!seen) {  // Seen once per network interface.
            all->push_back(CastDevice{s.fn, s.md, s.host, s.addr, s.port});
          }
        } else {
          result = CastDevice{s.fn, s.md, s.host, s.addr, s.port};
        }
      }
    }
  }
  DNSServiceRefDeallocate(browse);
  return result;
}
}  // namespace

std::optional<CastDevice> FindCastDevice(const std::string& name,
                                         std::chrono::milliseconds timeout) {
  return Browse(name, timeout, false, nullptr);
}

std::vector<CastDevice> ListCastDevices(std::chrono::milliseconds timeout) {
  std::vector<CastDevice> all;
  Browse("", timeout, true, &all);
  return all;
}

}  // namespace nestcast
