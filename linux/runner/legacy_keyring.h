#ifndef RUNNER_LEGACY_KEYRING_H_
#define RUNNER_LEGACY_KEYRING_H_

// Copies a NeoStation beta's keyring entry (com.neogamelab.neostation) to
// this build's, when this build has none yet.
//
// flutter_secure_storage keeps every credential (NeoSync, RetroAchievements,
// RomM, ScreenScraper) in one Secret Service entry named after the
// application id, so the release candidate (dev.misoba.neostation) would not
// find the beta's. Does nothing without a running Secret Service: gaming
// distributions keep credentials in an encrypted file in the user data, which
// does not move.
void legacy_keyring_import(const char* current_id);

#endif  // RUNNER_LEGACY_KEYRING_H_
