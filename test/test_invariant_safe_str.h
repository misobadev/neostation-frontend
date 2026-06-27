#include <check.h>
#include <stdlib.h>
#include <string.h>
#include "packages/flutter_soloud/android/include/share/safe_str.h"

START_TEST(test_strncat_no_overflow)
{
    // Invariant: strncat_s never writes beyond the declared buffer size
    const char *payloads[] = {
        "A",  // Valid input (boundary case - single char)
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ",  // Exact exploit case - exceeds typical small buffers
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",  // 100 chars - significantly oversized
        "test",  // Normal valid input
        ""  // Empty string
    };
    int num_payloads = sizeof(payloads) / sizeof(payloads[0]);

    for (int i = 0; i < num_payloads; i++) {
        char dest[16] = "base";  // Small buffer
        char dest_copy[16];
        strcpy(dest_copy, dest);
        
        // Test the actual production function
        errno_t result = strncat_s(dest, sizeof(dest), payloads[i], strlen(payloads[i]));
        
        // Property: No buffer overflow occurred
        // Either the operation succeeded safely or was rejected
        ck_assert_msg(result == 0 || result == ERANGE, 
                     "strncat_s must either succeed or return ERANGE for oversized inputs");
        
        // Additional check: if succeeded, ensure null termination
        if (result == 0) {
            ck_assert_msg(dest[sizeof(dest)-1] == '\0' || strlen(dest) < sizeof(dest),
                         "Buffer must be properly null-terminated");
        }
    }
}
END_TEST

Suite *security_suite(void)
{
    Suite *s;
    TCase *tc_core;

    s = suite_create("Security");
    tc_core = tcase_create("Core");

    tcase_add_test(tc_core, test_strncat_no_overflow);
    suite_add_tcase(s, tc_core);

    return s;
}

int main(void)
{
    int number_failed;
    Suite *s;
    SRunner *sr;

    s = security_suite();
    sr = srunner_create(s);

    srunner_run_all(sr, CK_NORMAL);
    number_failed = srunner_ntests_failed(sr);
    srunner_free(sr);

    return (number_failed == 0) ? EXIT_SUCCESS : EXIT_FAILURE;
}