/* tests/search_harness.c - deterministic harness for `cov-analysis search`
 * tests. Different inputs reach different lines, so the search command can be
 * verified to attribute lines to the correct inputs. Link with tests/cov.c
 * (the replay driver providing main()).
 */
#include <stddef.h>
#include <stdint.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size < 1) {
        return 0;
    }
    if (data[0] == 'A') {
        volatile int a = 1; (void)a;   /* SEARCH_LINE_A */
    } else if (data[0] == 'B') {
        volatile int b = 2; (void)b;   /* SEARCH_LINE_B */
    } else if (data[0] == 'Z') {
        volatile int z = 3; (void)z;   /* SEARCH_LINE_Z (never reached by corpus) */
    }
    return 0;
}
