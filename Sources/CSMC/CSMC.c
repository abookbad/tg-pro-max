#include "CSMC.h"
#include <IOKit/IOKitLib.h>
#include <string.h>
#include <math.h>
// AppleSMC user-client ABI. Only read (5), index (8), and info (9) commands exist here.
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } Version;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, memory; } Limits;
typedef struct {
    uint32_t key; Version version; Limits limits; TGKeyInfo info;
    uint8_t result, status, command; uint32_t data; uint8_t bytes[32];
} Message;
_Static_assert(sizeof(Message) == 80, "SMC ABI mismatch");
static bool call(uint32_t connection, Message *in, Message *out) {
    size_t size = sizeof(*out);
    return IOConnectCallStructMethod(connection, 2, in, sizeof(*in), out, &size) == KERN_SUCCESS
        && size == sizeof(*out) && out->result == 0;
}
uint32_t tg_smc_open(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return 0;
    io_connect_t connection = 0;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    return result == KERN_SUCCESS ? connection : 0;
}
void tg_smc_close(uint32_t connection) { if (connection) IOServiceClose(connection); }
bool tg_smc_key_at(uint32_t c, uint32_t index, uint32_t *key) {
    Message in = {0}, out = {0}; in.command = 8; in.data = index;
    if (!call(c, &in, &out)) return false;
    *key = out.key; return true;
}
bool tg_smc_info(uint32_t c, uint32_t key, TGKeyInfo *info) {
    Message in = {0}, out = {0}; in.command = 9; in.key = key;
    if (!call(c, &in, &out) || out.info.size == 0 || out.info.size > 32) return false;
    *info = out.info; return true;
}
#define FCC(a,b,c,d) (((uint32_t)a<<24)|((uint32_t)b<<16)|((uint32_t)c<<8)|d)
bool tg_smc_decode(uint32_t type, const uint8_t *b, uint32_t size, double *value) {
    if (type == FCC('f','l','t',' ') && size == 4) {
        uint32_t bits = (uint32_t)b[0] | ((uint32_t)b[1]<<8) | ((uint32_t)b[2]<<16) | ((uint32_t)b[3]<<24);
        float f; memcpy(&f, &bits, 4); *value = f;
    } else if (type == FCC('s','p','7','8') && size == 2) {
        *value = (int16_t)((b[0]<<8)|b[1]) / 256.0;
    } else if (type == FCC('f','p','e','2') && size == 2) {
        *value = ((b[0]<<8)|b[1]) / 4.0;
    } else if ((type == FCC('u','i','8',' ') && size == 1) ||
               (type == FCC('u','i','1','6') && size == 2) ||
               (type == FCC('u','i','3','2') && size == 4)) {
        uint32_t n = 0; for (uint32_t i=0; i<size; i++) n = (n<<8)|b[i]; *value = n;
    } else return false;
    return isfinite(*value);
}
bool tg_smc_read(uint32_t c, uint32_t key, TGKeyInfo info, double *value) {
    if (!info.size || info.size > 32) return false;
    Message in = {0}, out = {0}; in.command = 5; in.key = key; in.info = info;
    return call(c, &in, &out) && tg_smc_decode(info.type, out.bytes, info.size, value);
}
