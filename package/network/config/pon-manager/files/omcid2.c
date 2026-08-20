/* SPDX-License-Identifier: GPL-2.0 */
/*
 * omcid2.c - G.988 OMCI protocol daemon for Airoha AN7581 (OpenWrt)
 *
 * Adapted from AKoo7's econet-omcid (EN7528) for the AN7581 kmod-airoha-pon
 * ABI. The original used an AF_PACKET socket on an "omci" netdev and
 * programmed the datapath through /proc/econet_xpon_*. On AN7581 the OMCI
 * frame plane is the /dev/airoha_pon character device:
 *   TX: ioctl(AIR_PON_SEND_OMCI)
 *   RX: read() returns records { u16 len, payload[] }
 * The data-plane GEM/ALLOC mapping is handled by the upstream airoha_eth
 * driver + netifd VLANs (pon0.xxx), so the proc writes are stubbed.
 *
 * Build: $(TARGET_CC) -o omcid2 omcid2.c
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <time.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <syslog.h>

#include "pon_abi.h"

/* ---- OMCI baseline constants ---- */
#define OMCI_LEN        44
#define DEV_ID          0x0a
#define AR_BIT          0x40
#define AK_BIT          0x20
#define MT_MASK         0x1f
#define MT_CREATE       0x04
#define MT_DELETE       0x06
#define MT_SET          0x08
#define MT_GET          0x09
#define MT_GET_ALL_ALARM 0x0b
#define MT_GET_ALL_ALARM_NEXT 0x0c
#define MT_MIB_UPLOAD   0x0d
#define MT_MIB_UPLOAD_NEXT 0x0e
#define MT_MIB_RESET    0x0f
#define MT_TEST         0x12
#define MT_REBOOT       0x17
#define MT_SYNC_TIME    0x18
#define MT_GET_NEXT     0x1a
#define MT_GET_CUR_DATA 0x1b
#define MT_SET_TABLE    0x1c
#define RC_OK           0x00
#define RC_PROC_ERR     0x01
#define RC_NOT_SUPPORTED 0x03
#define RC_PARAM_ERR    0x04
#define RC_UNKNOWN_ME   0x05
#define RC_UNKNOWN_INST 0x06

/* ---- MIB store ---- */
#define MAX_ME 512
struct me {
    uint16_t cls;
    uint16_t inst;
    uint8_t  attr[128];
    uint8_t  in_use;
    uint8_t  pre;
};
static struct me mib[MAX_ME];
static int mib_n;
static uint8_t mib_data_sync;

static uint64_t now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static uint64_t t0;
#define LOG(...) do { syslog(LOG_INFO, __VA_ARGS__); } while (0)

static struct me *mib_find(uint16_t cls, uint16_t inst)
{
    int i;
    for (i = 0; i < mib_n; i++)
        if (mib[i].in_use && mib[i].cls == cls && mib[i].inst == inst)
            return &mib[i];
    return NULL;
}

static struct me *mib_add(uint16_t cls, uint16_t inst, int pre)
{
    struct me *m = mib_find(cls, inst);
    if (m) return m;
    if (mib_n >= MAX_ME) return NULL;
    m = &mib[mib_n++];
    memset(m, 0, sizeof(*m));
    m->cls = cls; m->inst = inst; m->in_use = 1; m->pre = pre ? 1 : 0;
    return m;
}

static void mib_del(uint16_t cls, uint16_t inst)
{
    int i;
    for (i = 0; i < mib_n; i++)
        if (mib[i].in_use && mib[i].cls == cls && mib[i].inst == inst) {
            mib[i].in_use = 0;
            return;
        }
}

static const char *MIB_FILE = "/tmp/omcid2_mib.dump";
static void mib_save(void)
{
    FILE *f = fopen(MIB_FILE, "w");
    int i, j;
    if (!f) return;
    fprintf(f, "MDS %u\n", mib_data_sync);
    for (i = 0; i < mib_n; i++) {
        if (!mib[i].in_use) continue;
        fprintf(f, "%u %u %u ", mib[i].cls, mib[i].inst, mib[i].pre);
        for (j = 0; j < 128; j++)
            fprintf(f, "%02x", mib[i].attr[j]);
        fputc('\n', f);
    }
    fclose(f);
}

static void mib_load(void)
{
    FILE *f = fopen(MIB_FILE, "r");
    char line[512];
    int n = 0;
    unsigned a, b, c;
    char hx[300];

    if (!f) { LOG("mib_load: no %s (fresh MIB)", MIB_FILE); return; }
    while (fgets(line, sizeof(line), f)) {
        if (sscanf(line, "MDS %u", &a) == 1) { mib_data_sync = (uint8_t)a; continue; }
        if (sscanf(line, "%u %u %u %256s", &a, &b, &c, hx) == 4) {
            struct me *m = mib_add((uint16_t)a, (uint16_t)b, (int)c);
            if (m) {
                int L = (int)strlen(hx) / 2;
                int j;
                if (L > 128) L = 128;
                for (j = 0; j < L; j++) {
                    unsigned v = 0;
                    sscanf(hx + 2 * j, "%2x", &v);
                    m->attr[j] = (uint8_t)v;
                }
                n++;
            }
        }
    }
    fclose(f);
    LOG("mib_load: %d provisioned MEs from %s (mds=%u)", n, MIB_FILE, mib_data_sync);
}

/* ---- datapath programming (AN7581 stub) ----
 * On AN7581 the GEM->netdev mapping is done by airoha_eth + netifd VLANs.
 * We log the provisioned GEM/tcont but do not touch /proc here. */
static void datapath_create_gem(struct me *m)
{
    uint16_t portid = (m->attr[0] << 8) | m->attr[1];
    uint16_t tcont_ptr = (m->attr[2] << 8) | m->attr[3];
    struct me *tc = mib_find(262, tcont_ptr);
    uint16_t alloc = tc ? ((tc->attr[0] << 8) | tc->attr[1]) : 0;
    LOG("GEM-CTP create: portId=%u tcontPtr=0x%x alloc=%u (datapath via pon0.VLAN)",
        portid, tcont_ptr, alloc);
}

/* ---- attribute-size tables ---- */
struct attrtab { uint16_t cls; uint8_t size[16]; };
static const struct attrtab attrtabs[] = {
    { 256, {4, 14, 8, 1, 1, 1, 1, 1, 1, 24, 12, 1, 2, 0} },
    { 65530, {4, 4, 4, 4, 4, 4, 4, 4, 0} },
    { 257, {20, 1, 2, 1, 1, 2, 1, 1, 1, 2, 2, 0} },
    { 2, {1, 0} },
    { 7, {14, 1, 1, 1, 25, 16, 0} },
    { 263, {1, 1, 2, 1, 1, 1, 1, 1, 1, 2, 1, 1, 2, 2, 1, 1} },
    { 277, {1, 2, 2, 2, 2, 4, 2, 1, 2, 4, 2, 2, 0} },
    { 278, {2, 2, 1, 1, 0} },
    { 262, {2, 1, 1, 0} },
    { 266, {2, 1, 2, 2, 1, 1, 2, 1, 0} },
    { 268, {2, 2, 1, 2, 2, 1, 2, 1, 2, 1, 0} },
    { 45, {1, 1, 1, 2, 2, 2, 2, 1, 1, 4, 0} },
    { 47, {2, 1, 1, 2, 2, 2, 1, 1, 1, 6, 2, 2, 1, 0} },
    { 84, {24, 1, 1, 0} },
    { 272, {2, 0} },
    { 281, {2, 1, 2, 2, 1, 1, 2, 1, 0} },
    { 329, {1, 1, 25, 2, 2, 0} },
    { 11, {1, 1, 1, 1, 1, 1, 1, 2, 1, 2, 1, 1, 1, 1, 1, 0} },
    { 0, {0} }
};
static const struct attrtab *find_attrtab(uint16_t cls)
{
    const struct attrtab *a;
    for (a = attrtabs; a->cls; a++)
        if (a->cls == cls) return a;
    return NULL;
}

/* ---- transport over /dev/airoha_pon ---- */
static int g_omci_fd = -1;

static void send_resp(const uint8_t *req, const uint8_t *content, int clen)
{
    uint8_t r[OMCI_LEN];
    struct air_pon_omci o;
    int n;

    memset(r, 0, sizeof(r));
    r[0] = req[0]; r[1] = req[1];
    r[2] = (req[2] & MT_MASK) | AK_BIT;
    r[3] = DEV_ID;
    r[4] = req[4]; r[5] = req[5];
    r[6] = req[6]; r[7] = req[7];
    if (content && clen > 0) {
        if (clen > 32) clen = 32;
        memcpy(r + 8, content, clen);
    }
    r[40] = 0x00; r[41] = 0x00; r[42] = 0x00; r[43] = 0x28;

    if (g_omci_fd < 0) { LOG("send_resp: no OMCI fd"); return; }
    memset(&o, 0, sizeof(o));
    o.len = OMCI_LEN;
    memcpy(o.msg, r, OMCI_LEN);
    n = ioctl(g_omci_fd, AIR_PON_SEND_OMCI, &o);
    if (n < 0) LOG("send_resp OMCI TX fail: %s", strerror(errno));
}

/* ---- handlers ---- */
static void h_mib_reset(const uint8_t *req)
{
    int kept = 0;
    int i;
    for (i = 0; i < mib_n; i++) {
        if (mib[i].in_use && !mib[i].pre) mib[i].in_use = 0;
        else if (mib[i].in_use) kept++;
    }
    mib_data_sync = 0;
    LOG("MIB-RESET -> cleared (kept %d pre-instantiated)", kept);
    {
        uint8_t c[32] = {0};
        c[0] = RC_OK;
        send_resp(req, c, 1);
    }
}

static int upload_count = -1;
static int no_selfcreate = 0;

static void h_mib_upload(const uint8_t *req)
{
    int cnt;
    uint8_t c[32] = {0};
    if (upload_count >= 0) cnt = upload_count;
    else {
        int i;
        cnt = 0;
        for (i = 0; i < mib_n; i++) if (mib[i].in_use) cnt++;
    }
    LOG("MIB-UPLOAD -> %d MEs", cnt);
    c[0] = (cnt >> 8) & 0xff; c[1] = cnt & 0xff;
    send_resp(req, c, 2);
}

static void h_mib_upload_next(const uint8_t *req)
{
    uint16_t seq = (req[8] << 8) | req[9];
    int k = 0, i;
    struct me *m = NULL;
    uint8_t c[32] = {0};
    for (i = 0; i < mib_n; i++)
        if (mib[i].in_use) { if (k == seq) { m = &mib[i]; break; } k++; }
    if (m) {
        const struct attrtab *t = find_attrtab(m->cls);
        uint16_t mask = 0;
        int off = 6, src = 0;
        int a;
        c[0] = (m->cls >> 8) & 0xff; c[1] = m->cls & 0xff;
        c[2] = (m->inst >> 8) & 0xff; c[3] = m->inst & 0xff;
        if (m->cls == 2) { mask = 0x8000; c[6] = mib_data_sync; off = 7; }
        else if (t) {
            for (a = 0; a < 16 && t->size[a]; a++) {
                int sz = t->size[a];
                if (off + sz <= 32 && src + sz <= (int)sizeof(m->attr)) {
                    mask |= (0x8000 >> a);
                    memcpy(c + off, m->attr + src, sz);
                    off += sz;
                }
                src += sz;
            }
        } else { mask = 0x8000; memcpy(c + 6, m->attr, 20); off = 26; }
        c[4] = (mask >> 8) & 0xff; c[5] = mask & 0xff;
        LOG("MIB-UPLOAD-NEXT seq=%u -> class=%u inst=%u mask=0x%04x %dB",
            seq, m->cls, m->inst, mask, off - 6);
    } else {
        LOG("MIB-UPLOAD-NEXT seq=%u -> (none)", seq);
    }
    send_resp(req, c, 32);
}

static void h_create(const uint8_t *req, uint16_t cls, uint16_t inst)
{
    struct me *m = mib_add(cls, inst, 0);
    if (m) { memcpy(m->attr, req + 8, 32); mib_data_sync++; }
    LOG("CREATE class=%u inst=%u -> %s (mds=%u)", cls, inst, m ? "ok" : "FULL", mib_data_sync);
    {
        uint8_t c[32] = {0};
        c[0] = m ? RC_OK : RC_PROC_ERR;
        send_resp(req, c, 3);
    }
    if (m && cls == 268) datapath_create_gem(m);
    if (m && cls == 266 && !no_selfcreate) {
        uint16_t ctp = (m->attr[0] << 8) | m->attr[1];
        if (ctp && ctp != 0x0fff && !mib_find(268, ctp)) {
            struct me *g = mib_add(268, ctp, 0);
            if (g) {
                g->attr[0] = (ctp >> 8) & 0xff; g->attr[1] = ctp & 0xff;
                g->attr[2] = 0x80; g->attr[3] = 0x00;
                g->attr[4] = 0x03;
                g->attr[5] = 0x80; g->attr[6] = 0x00;
                mib_data_sync++;
                LOG("SELF-CREATE GEM-CTP(268) inst=%u (OLT withheld it) -> MIB+datapath", ctp);
                datapath_create_gem(g);
            }
        }
    }
    if (m) mib_save();
}

static void h_delete(const uint8_t *req, uint16_t cls, uint16_t inst)
{
    uint8_t c[32] = {0};
    mib_del(cls, inst); mib_data_sync++;
    LOG("DELETE class=%u inst=%u", cls, inst);
    c[0] = RC_OK;
    send_resp(req, c, 1);
    mib_save();
}

static void h_set(const uint8_t *req, uint16_t cls, uint16_t inst)
{
    struct me *m = mib_find(cls, inst);
    uint16_t mask = (req[8] << 8) | req[9];
    const struct attrtab *st = find_attrtab(cls);
    uint8_t c[32] = {0};
    if (!m) m = mib_add(cls, inst, 0);
    if (m) {
        if (st) {
            int moff = 0, roff = 0, a;
            for (a = 0; a < 16 && st->size[a]; a++) {
                int sz = st->size[a];
                if (mask & (0x8000 >> a)) {
                    if (moff + sz <= (int)sizeof(m->attr) && roff + sz <= 22)
                        memcpy(m->attr + moff, req + 10 + roff, sz);
                    roff += sz;
                }
                moff += sz;
            }
        } else {
            memcpy(m->attr, req + 10, 22);
        }
    }
    if (cls == 2 && (mask & 0x8000)) mib_data_sync = req[10];
    else mib_data_sync++;
    LOG("SET class=%u inst=%u mask=0x%04x (mds=%u)", cls, inst, mask, mib_data_sync);
    if (cls == 262) {
        int i;
        for (i = 0; i < mib_n; i++)
            if (mib[i].in_use && mib[i].cls == 268) {
                uint16_t tp = (mib[i].attr[2] << 8) | mib[i].attr[3];
                if (tp == inst) {
                    LOG("  rebind GEM-CTP %u after T-CONT %u set", mib[i].inst, inst);
                    datapath_create_gem(&mib[i]);
                }
            }
    }
    c[0] = m ? RC_OK : RC_UNKNOWN_INST;
    send_resp(req, c, 1);
    if (m) mib_save();
}

static void h_get(const uint8_t *req, uint16_t cls, uint16_t inst)
{
    struct me *m = mib_find(cls, inst);
    uint16_t mask = (req[8] << 8) | req[9];
    uint8_t c[32] = {0};
    if (!m) {
        c[0] = RC_UNKNOWN_INST;
        LOG("GET class=%u inst=%u -> unknown inst", cls, inst);
        send_resp(req, c, 3);
        return;
    }
    {
        const struct attrtab *t = find_attrtab(cls);
        int off = 3, src = 0, a;
        c[0] = RC_OK; c[1] = (mask >> 8) & 0xff; c[2] = mask & 0xff;
        if (cls == 2) {
            if (mask & 0x8000) c[off++] = mib_data_sync;
        } else if (t) {
            for (a = 0; a < 16 && t->size[a]; a++) {
                int sz = t->size[a];
                if (mask & (0x8000 >> a)) {
                    if (off + sz <= 32 && src + sz <= (int)sizeof(m->attr))
                        memcpy(c + off, m->attr + src, sz);
                    off += sz;
                }
                src += sz;
            }
        } else {
            memcpy(c + off, m->attr, 26); off = 29;
        }
        LOG("GET class=%u inst=%u mask=0x%04x -> %d bytes", cls, inst, mask, off - 3);
        send_resp(req, c, off);
    }
}

static void h_generic_ok(const uint8_t *req, const char *name)
{
    uint8_t c[32] = {0};
    LOG("%s -> ok", name);
    c[0] = RC_OK;
    send_resp(req, c, 1);
}

/* ---- ONU serial ---- */
static uint8_t g_onu_sn[8];

static int parse_onu_sn(const char *s)
{
    uint8_t sn[8];
    int i;
    if (!s || strlen(s) != 12) return 0;
    memcpy(sn, s, 4);
    for (i = 0; i < 4; i++) {
        char h[3] = {s[4 + i * 2], s[5 + i * 2], 0};
        char *end = NULL;
        unsigned long v = strtoul(h, &end, 16);
        if (end != h + 2) return 0;
        sn[4 + i] = (uint8_t)v;
    }
    memcpy(g_onu_sn, sn, 8);
    return 1;
}

/* ---- seed MIB ---- */
static void seed_mib(void)
{
    struct me *m;
    int i;
    m = mib_add(256, 0, 1);
    memcpy(m->attr, g_onu_sn, 4);
    memset(m->attr + 4, 0x20, 14);
    memcpy(m->attr + 4, "RP0201", 6);
    memcpy(m->attr + 18, g_onu_sn, 8);
    m->attr[26] = 0x02;
    m->attr[31] = 0x0a;
    m->attr[69] = 0x00; m->attr[70] = 0x03;
    m = mib_add(257, 0, 1);
    m->attr[20] = 0xA1; m->attr[21] = 0x01; m->attr[22] = 0x54; m->attr[23] = 0x01;
    mib_add(2, 0, 1);
    mib_add(263, 0x8001, 1);
    for (i = 0; i < 8; i++) mib_add(262, 0x8000 + i, 1);
    mib_add(329, 0x0A01, 1);
    for (i = 0; i < 4; i++) mib_add(11, 0x0101 + i, 1);
    m = mib_add(7, 0, 1);
    memcpy(m->attr, "V3.2.2120054  ", 14); m->attr[14] = 1; m->attr[15] = 1; m->attr[16] = 1;
    m = mib_add(7, 1, 1);
    memcpy(m->attr, "V3.2.2120040  ", 14); m->attr[14] = 0; m->attr[15] = 0; m->attr[16] = 1;
    mib_add(65530, 0, 1);
    LOG("seeded baseline MIB: %d MEs", mib_n);
}

static void usage(const char *prog)
{
    fprintf(stderr,
        "usage: %s [serial]\n"
        "  serial  ONU serial VVVVXXXXXXXX (4 vendor ASCII + 8 hex)\n",
        prog);
    exit(1);
}

int main(int argc, char **argv)
{
    const char *serial = getenv("OMCID2_SERIAL");
    int fd;
    uint8_t buf[AIR_PON_OMCI_MAX + 2];
    const char *e;

    openlog("omcid2", LOG_PID | LOG_NDELAY, LOG_DAEMON);
    t0 = now_ms();

    if (argc > 1) {
        if (!strcmp(argv[1], "-h") || !strcmp(argv[1], "--help"))
            usage(argv[0]);
        serial = argv[1];
    }
    if (!parse_onu_sn(serial))
        LOG("WARNING: no/invalid ONU serial; ONU may not register until provisioned");

    e = getenv("OMCID2_NOSELFCREATE");
    if (e && e[0] == '1') no_selfcreate = 1;

    fd = open(AIR_PON_DEV, O_RDWR);
    if (fd < 0) {
        LOG("open %s failed: %s", AIR_PON_DEV, strerror(errno));
        return 1;
    }
    g_omci_fd = fd;
    LOG("omcid2 up on %s no_selfcreate=%d", AIR_PON_DEV, no_selfcreate);

    seed_mib();
    mib_load();

    for (;;) {
        ssize_t n = read(fd, buf, sizeof(buf));
        uint8_t mt, ar;
        uint16_t cls, inst;
        uint16_t len;
        if (n < 2) continue;
        len = *(uint16_t *)buf;
        if ((ssize_t)len + 2 > n) len = (uint16_t)(n - 2);
        if (len < 8) continue;
        if (buf[2 + 3] != DEV_ID) continue; /* offset 3 in payload */
        mt = buf[2 + 2] & MT_MASK;
        ar = (buf[2 + 2] & AR_BIT) != 0;
        cls = (buf[2 + 4] << 8) | buf[2 + 5];
        inst = (buf[2 + 6] << 8) | buf[2 + 7];
        if (!ar) continue;
        switch (mt) {
        case MT_MIB_RESET:      h_mib_reset(buf + 2); break;
        case MT_MIB_UPLOAD:     h_mib_upload(buf + 2); break;
        case MT_MIB_UPLOAD_NEXT:h_mib_upload_next(buf + 2); break;
        case MT_CREATE:         h_create(buf + 2, cls, inst); break;
        case MT_DELETE:         h_delete(buf + 2, cls, inst); break;
        case MT_SET:            h_set(buf + 2, cls, inst); break;
        case MT_GET:            h_get(buf + 2, cls, inst); break;
        case MT_GET_ALL_ALARM:  { uint8_t c[32] = {0}; LOG("GET-ALL-ALARMS -> 0"); send_resp(buf + 2, c, 2); } break;
        case MT_SYNC_TIME:      h_generic_ok(buf + 2, "SYNC-TIME"); break;
        case MT_TEST:           h_generic_ok(buf + 2, "TEST"); break;
        case MT_REBOOT:         h_generic_ok(buf + 2, "REBOOT(ignored)"); break;
        case MT_GET_NEXT:       { uint8_t c[32] = {0}; c[0] = RC_OK; LOG("GET-NEXT class=%u inst=%u (stub)", cls, inst); send_resp(buf + 2, c, 29); } break;
        default:                LOG("UNHANDLED mt=0x%02x class=%u inst=%u", mt, cls, inst); h_generic_ok(buf + 2, "generic"); break;
        }
    }
    return 0;
}
