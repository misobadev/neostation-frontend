#include "legacy_keyring.h"

#include <gio/gio.h>
#include <libsecret/secret.h>

namespace {

constexpr char kLegacyId[] = "com.neogamelab.neostation";

// Asked of the bus rather than of libsecret, which would try to start a
// Secret Service that isn't installed and wait for it.
bool secret_service_running() {
  g_autoptr(GError) error = nullptr;
  g_autoptr(GDBusConnection) bus =
      g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (bus == nullptr) return false;
  g_autoptr(GVariant) reply = g_dbus_connection_call_sync(
      bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "NameHasOwner",
      g_variant_new("(s)", "org.freedesktop.secrets"), G_VARIANT_TYPE("(b)"),
      G_DBUS_CALL_FLAGS_NONE, 2000, nullptr, &error);
  if (reply == nullptr) return false;
  gboolean owned = FALSE;
  g_variant_get(reply, "(b)", &owned);
  return owned;
}

// The schema and attribute flutter_secure_storage_linux stores under.
struct StorageEntry {
  explicit StorageEntry(const char* id)
      : name(g_strdup_printf("%s/FlutterSecureStorage", id)),
        account(g_strdup_printf("%s.secureStorage", id)) {
    schema.name = name;
    schema.flags = SECRET_SCHEMA_NONE;
    schema.attributes[0] = {"account", SECRET_SCHEMA_ATTRIBUTE_STRING};
    schema.attributes[1] = {nullptr, SECRET_SCHEMA_ATTRIBUTE_STRING};
  }
  ~StorageEntry() {
    g_free(name);
    g_free(account);
  }

  gchar* lookup(GError** error) const {
    return secret_password_lookup_sync(&schema, nullptr, error, "account",
                                       account, nullptr);
  }

  gboolean store(const gchar* value, GError** error) const {
    return secret_password_store_sync(&schema, SECRET_COLLECTION_DEFAULT, name,
                                      value, nullptr, error, "account",
                                      account, nullptr);
  }

  gchar* name;
  gchar* account;
  SecretSchema schema = {};
};

bool has_content(const gchar* value) {
  // An entry the plugin emptied is "{}".
  return value != nullptr && value[0] != '\0' && g_strcmp0(value, "{}") != 0;
}

}  // namespace

void legacy_keyring_import(const char* current_id) {
  if (g_strcmp0(current_id, kLegacyId) == 0) return;
  if (!secret_service_running()) return;

  const StorageEntry current(current_id);
  g_autoptr(GError) error = nullptr;
  gchar* existing = current.lookup(&error);
  if (error != nullptr) {
    g_warning("Beta keyring import: could not read this build's entry: %s",
              error->message);
    return;
  }
  const bool already = has_content(existing);
  secret_password_free(existing);
  if (already) return;

  const StorageEntry legacy(kLegacyId);
  gchar* old_value = legacy.lookup(&error);
  if (error != nullptr) {
    g_warning("Beta keyring import: could not read the beta's entry: %s",
              error->message);
    return;
  }
  if (has_content(old_value) && !current.store(old_value, &error)) {
    g_warning("Beta keyring import: could not store the entry: %s",
              error != nullptr ? error->message : "unknown error");
  }
  secret_password_free(old_value);
}
