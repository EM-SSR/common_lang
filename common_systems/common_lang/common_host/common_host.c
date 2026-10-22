/* common_host — hosted x86-64 image の実行台
 *
 * 仕様は docs/common-compiler/arch/18。host がやることは三つだけになる。
 *
 *   確保  語配列 8·S·W byte と、image を写す実行可能領域
 *   起動  lane ごとに thread を作り、RDI = W_base(l)、RSI = S で呼ぶ   （18 式 3.2）
 *   読み  thread が全部戻った後、語配列と返り値を読む                  （18 式 7.1）
 *
 * image の中身は読まない。意味は Common 側にあり、host は byte を写す器になる。
 *
 * 呼び出し規約は System V AMD64 である。Windows の既定は Microsoft x64 なので、
 * 関数ポインタへ sysv_abi を付けて compiler に切り替えさせる。この属性は
 * gcc と clang が持つ。MSVC には無いので、この file は gcc か clang で通す。
 *
 * 作業領域は lane ごとに切れているので（18 式 6.2）、排他制御が要らない。
 *
 *   gcc -O2 -o common_host.exe common_host.c
 *   common_host image.bin --lanes 8 --words 65536 --in corpus.txt --dump 16
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <sys/mman.h>
#include <pthread.h>
#include <unistd.h>
#endif

/* 18 式 (7.1)。第一引数が作業領域の基底、第二引数が語数になる */
#if defined(__GNUC__) || defined(__clang__)
typedef uint64_t (*entry_fn)(uint64_t *w, uint64_t n) __attribute__((sysv_abi));
#else
typedef uint64_t (*entry_fn)(uint64_t *w, uint64_t n);
#endif

/* ===== lane（18 §6）===== */

typedef struct {
    entry_fn  entry;
    uint64_t *work;      /* W_base(l) = W_0 + 8·S·l */
    uint64_t  words;     /* S */
    uint64_t  ret;       /* RAX。0 が Ok、それ以外が Ko */
} lane_t;

#ifdef _WIN32
static DWORD WINAPI lane_run(LPVOID p)
{
    lane_t *L = (lane_t *)p;
    L->ret = L->entry(L->work, L->words);
    return 0;
}
#else
static void *lane_run(void *p)
{
    lane_t *L = (lane_t *)p;
    L->ret = L->entry(L->work, L->words);
    return NULL;
}
#endif

/* ===== 作業領域（18 §6.1）=====
 *
 * lane ごとの区間は重ならない。意味 program は語数 S を RSI で受け取るが、
 * 範囲の検査は program の側にある。守りが無いと、はみ出した書き込みが
 * 隣の lane を黙って壊す。lane の後ろへ触れない頁を一枚置いて、はみ出しを
 * その場で落とす。
 *
 *   W_base(l) = W_0 + Δ·l,   Δ = round_up(8S, page) + page
 */

static size_t page_size(void)
{
#ifdef _WIN32
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    return (size_t)si.dwPageSize;
#else
    return (size_t)sysconf(_SC_PAGESIZE);
#endif
}

static size_t round_up(size_t n, size_t g) { return (n + g - 1) / g * g; }

/* どちらの API も零で埋めて返す。意味 program は未書き込みの語を 0 として読む */
static unsigned char *alloc_lanes(uint64_t lanes, uint64_t words, size_t *stride)
{
    size_t pg = page_size();
    size_t span = round_up((size_t)words * 8, pg);
    size_t total = (span + pg) * (size_t)lanes;
    unsigned char *p;
    uint64_t l;
    *stride = span + pg;
#ifdef _WIN32
    p = (unsigned char *)VirtualAlloc(NULL, total, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!p) return NULL;
    for (l = 0; l < lanes; l++) {
        DWORD old;
        if (!VirtualProtect(p + l * (span + pg) + span, pg, PAGE_NOACCESS, &old)) return NULL;
    }
#else
    p = (unsigned char *)mmap(NULL, total, PROT_READ | PROT_WRITE,
                              MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return NULL;
    for (l = 0; l < lanes; l++)
        if (mprotect(p + l * (span + pg) + span, pg, PROT_NONE) != 0) return NULL;
#endif
    return p;
}

/* ===== 実行可能領域 ===== */

static void *map_exec(const unsigned char *img, size_t n)
{
#ifdef _WIN32
    void *p = VirtualAlloc(NULL, n, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    DWORD old;
    if (!p) return NULL;
    memcpy(p, img, n);
    if (!VirtualProtect(p, n, PAGE_EXECUTE_READ, &old)) return NULL;
    FlushInstructionCache(GetCurrentProcess(), p, n);
    return p;
#else
    void *p = mmap(NULL, n, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return NULL;
    memcpy(p, img, n);
    if (mprotect(p, n, PROT_READ | PROT_EXEC) != 0) return NULL;
    return p;
#endif
}

/* ===== 入出力 ===== */

static unsigned char *read_all(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    unsigned char *buf;
    long n;
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n < 0) { fclose(f); return NULL; }
    buf = (unsigned char *)malloc((size_t)n + 1);
    if (!buf) { fclose(f); return NULL; }
    if (fread(buf, 1, (size_t)n, f) != (size_t)n) { free(buf); fclose(f); return NULL; }
    fclose(f);
    *len = (size_t)n;
    return buf;
}

/* 18 §7.1。語 0 が byte 数、基底以降が一語一 byte の本文になる。
 * 意味 program は Load だけで文字を取れる。MBox に shift も mask も無いので、
 * 一語へ詰め込むと program 側で除算が要る */
#define IN_BASE 64

/* 基底が要る理由。commonc は compile した program のワイヤ w を語 64+w へ置く
 * （19 式 3.2）。既定の 64 はそのワイヤ帯と重なるので、compile した .cmn は
 * 本文の代わりに自分のワイヤを読む。commonc 自身は .cam であり割付が別なので
 * 踏まない。--in-base が本文をワイヤ帯の上へ逃がす。
 *
 *   語 0   N    byte 数
 *   語 1   IB   本文の基底語番号
 *   語 IB..     本文の byte
 */
static uint64_t load_input(uint64_t *w, uint64_t words, const char *path, uint64_t base)
{
    size_t n = 0, i;
    unsigned char *b = read_all(path, &n);
    if (!b) { fprintf(stderr, "入力を読めない: %s\n", path); exit(2); }
    if (base + n > words) n = (size_t)(words - base);
    w[0] = (uint64_t)n;
    w[1] = base;
    for (i = 0; i < n; i++) w[i + base] = (uint64_t)b[i];
    free(b);
    return (uint64_t)n;
}

/* 19 §3.1。compile した image を取り出す。
 *   語 1 が基底語番号、語 2 が byte 数、その語が一語一 byte で image を持つ */
static int emit_image(const uint64_t *w, uint64_t words, const char *path)
{
    uint64_t base = w[1], n = w[2], i;
    FILE *f;
    if (base == 0 || n == 0) { fprintf(stderr, "image が空（語1=%llu 語2=%llu）\n",
                                       (unsigned long long)base, (unsigned long long)n); return 1; }
    if (base + n > words) { fprintf(stderr, "image が作業領域を越える\n"); return 1; }
    f = fopen(path, "wb");
    if (!f) { fprintf(stderr, "出力を開けない: %s\n", path); return 1; }
    for (i = 0; i < n; i++) fputc((int)(w[base + i] & 0xFF), f);
    fclose(f);
    printf("image  : %s  %llu byte  （要る語数 %llu）\n", path,
           (unsigned long long)n, (unsigned long long)w[3]);
    return 0;
}

static void usage(void)
{
    fprintf(stderr,
        "common_host <image.bin> [option]\n"
        "  --lanes W    lane 数。既定 1（18 式 6.1）\n"
        "  --words S    lane あたりの語数。既定 4096\n"
        "  --in F       lane 0 の作業領域へ F を写す。語 0 が byte 数、語 1 が基底\n"
        "  --in-base B  本文の基底語番号。既定 64。compile した .cmn はワイヤを\n"
        "               語 64.. へ置くので、そこより上へ逃がす\n"
        "  --dump N     復帰後に語 0..N-1 を出す\n"
        "  --out F      作業領域全体を byte 列として書き出す\n"
        "  --emit F     lane 0 が組んだ image を取り出す（19 §3.1）\n");
}

int main(int argc, char **argv)
{
    const char *img_path = NULL, *in_path = NULL, *out_path = NULL, *emit_path = NULL;
    uint64_t lanes = 1, words = 4096, dump = 0, in_base = IN_BASE;
    unsigned char *img;
    size_t img_len = 0;
    void *code;
    uint64_t *work;
    unsigned char *base;
    size_t stride = 0;
    lane_t *L;
    uint64_t l, i;
    int bad = 0;

    for (i = 1; i < (uint64_t)argc; i++) {
        const char *a = argv[i];
        if (strcmp(a, "--lanes") == 0 && i + 1 < (uint64_t)argc) lanes = strtoull(argv[++i], NULL, 10);
        else if (strcmp(a, "--words") == 0 && i + 1 < (uint64_t)argc) words = strtoull(argv[++i], NULL, 10);
        else if (strcmp(a, "--dump") == 0 && i + 1 < (uint64_t)argc) dump = strtoull(argv[++i], NULL, 10);
        else if (strcmp(a, "--in") == 0 && i + 1 < (uint64_t)argc) in_path = argv[++i];
        else if (strcmp(a, "--in-base") == 0 && i + 1 < (uint64_t)argc) in_base = strtoull(argv[++i], NULL, 10);
        else if (strcmp(a, "--out") == 0 && i + 1 < (uint64_t)argc) out_path = argv[++i];
        else if (strcmp(a, "--emit") == 0 && i + 1 < (uint64_t)argc) emit_path = argv[++i];
        else if (a[0] == '-') { usage(); return 2; }
        else img_path = a;
    }
    if (!img_path || lanes == 0 || words < 2 || in_base < 2) { usage(); return 2; }

    img = read_all(img_path, &img_len);
    if (!img) { fprintf(stderr, "image を読めない: %s\n", img_path); return 2; }
    code = map_exec(img, img_len);
    if (!code) { fprintf(stderr, "実行可能領域を取れない\n"); return 2; }

    base = alloc_lanes(lanes, words, &stride);
    L = (lane_t *)calloc((size_t)lanes, sizeof(lane_t));
    if (!base || !L) { fprintf(stderr, "作業領域を取れない\n"); return 2; }
    work = (uint64_t *)base;

    if (in_path) {
        uint64_t n = load_input(work, words, in_path, in_base);
        printf("入力   : %s  %llu byte -> 語 %llu..%llu\n",
               in_path, (unsigned long long)n, (unsigned long long)in_base,
               (unsigned long long)(in_base + n - 1));
    }

    for (l = 0; l < lanes; l++) {
        L[l].entry = (entry_fn)code;
        L[l].work  = (uint64_t *)(base + (size_t)l * stride);   /* 18 式 6.2 */
        L[l].words = words;
        L[l].ret   = 0;
    }

#ifdef _WIN32
    {
        HANDLE *th = (HANDLE *)calloc((size_t)lanes, sizeof(HANDLE));
        if (!th) { fprintf(stderr, "thread の表を取れない\n"); return 2; }
        for (l = 0; l < lanes; l++) th[l] = CreateThread(NULL, 0, lane_run, &L[l], 0, NULL);
        for (l = 0; l < lanes; l++) {
            if (th[l]) { WaitForSingleObject(th[l], INFINITE); CloseHandle(th[l]); }
            else { fprintf(stderr, "lane %llu の thread を作れない\n", (unsigned long long)l); bad = 1; }
        }
        free(th);
    }
#else
    {
        pthread_t *th = (pthread_t *)calloc((size_t)lanes, sizeof(pthread_t));
        if (!th) { fprintf(stderr, "thread の表を取れない\n"); return 2; }
        for (l = 0; l < lanes; l++) pthread_create(&th[l], NULL, lane_run, &L[l]);
        for (l = 0; l < lanes; l++) pthread_join(th[l], NULL);
        free(th);
    }
#endif

    for (l = 0; l < lanes; l++) {
        printf("lane %-3llu : %s (RAX=%llu)\n", (unsigned long long)l,
               L[l].ret == 0 ? "Ok" : "Ko", (unsigned long long)L[l].ret);
        if (L[l].ret != 0) bad = 1;
    }

    for (i = 0; i < dump && i < words; i++)
        printf("  語[%llu] = %lld\n", (unsigned long long)i, (long long)work[i]);

    if (emit_path && emit_image(work, words, emit_path) != 0) bad = 1;

    if (out_path) {
        FILE *f = fopen(out_path, "wb");
        if (!f) { fprintf(stderr, "出力を開けない: %s\n", out_path); return 2; }
        for (l = 0; l < lanes; l++)
            fwrite(base + (size_t)l * stride, sizeof(uint64_t), (size_t)words, f);
        fclose(f);
    }

    return bad;
}
