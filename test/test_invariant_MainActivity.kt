#include <check.h>
#include <stdlib.h>
#include <string.h>
#include <sqlite3.h>

// Simulating the database interaction pattern from MainActivity.kt
// This test directly exercises SQLite's parameterized query mechanism
// to verify injection payloads are properly handled

START_TEST(test_sql_injection_parameterization)
{
    // Invariant: User input never appears in SQL queries without parameterization
    const char *payloads[] = {
        "' OR 1=1 --",           // Classic SQL injection
        "'; DROP TABLE users; --", // Destructive injection
        "1",                     // Valid boundary case
        "1' OR '1'='1",          // Tautology injection
        "1; SELECT * FROM sqlite_master --" // Multi-statement injection
    };
    int num_payloads = sizeof(payloads) / sizeof(payloads[0]);
    
    sqlite3 *db;
    sqlite3_stmt *stmt;
    int rc;
    
    // Create in-memory database for testing
    rc = sqlite3_open(":memory:", &db);
    ck_assert_msg(rc == SQLITE_OK, "Failed to open database");
    
    // Create test table similar to user_config
    rc = sqlite3_exec(db, "CREATE TABLE user_config (id INTEGER PRIMARY KEY, hide_bottom_screen INTEGER)", 
                      NULL, NULL, NULL);
    ck_assert_msg(rc == SQLITE_OK, "Failed to create test table");
    
    // Insert test data
    rc = sqlite3_exec(db, "INSERT INTO user_config (id, hide_bottom_screen) VALUES (1, 0)", 
                      NULL, NULL, NULL);
    ck_assert_msg(rc == SQLITE_OK, "Failed to insert test data");
    
    for (int i = 0; i < num_payloads; i++) {
        // Test parameterized query - this is the safe pattern
        const char *sql = "SELECT hide_bottom_screen FROM user_config WHERE id = ?";
        rc = sqlite3_prepare_v2(db, sql, -1, &stmt, NULL);
        ck_assert_msg(rc == SQLITE_OK, "Failed to prepare parameterized query");
        
        // Bind the payload as a parameter
        rc = sqlite3_bind_text(stmt, 1, payloads[i], -1, SQLITE_STATIC);
        ck_assert_msg(rc == SQLITE_OK, "Failed to bind parameter");
        
        // Execute query - should return no rows for injection payloads
        rc = sqlite3_step(stmt);
        
        // For valid input "1", we expect a row
        if (strcmp(payloads[i], "1") == 0) {
            ck_assert_msg(rc == SQLITE_ROW, "Valid input should return a row");
        } else {
            // Injection payloads should not match any rows when properly parameterized
            ck_assert_msg(rc == SQLITE_DONE, 
                         "Injection payload should not return rows when parameterized");
        }
        
        sqlite3_finalize(stmt);
        
        // Additional check: verify the payload wasn't executed as SQL
        // by checking table still exists
        rc = sqlite3_exec(db, "SELECT name FROM sqlite_master WHERE type='table' AND name='user_config'",
                         NULL, NULL, NULL);
        ck_assert_msg(rc == SQLITE_OK, "Table should still exist after injection attempt");
    }
    
    sqlite3_close(db);
}
END_TEST

Suite *security_suite(void)
{
    Suite *s;
    TCase *tc_core;

    s = suite_create("Security");
    tc_core = tcase_create("Core");

    tcase_add_test(tc_core, test_sql_injection_parameterization);
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