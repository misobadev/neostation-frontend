#include "include/gamepads_linux/gamepads_linux_plugin.h"

#include <flutter_linux/flutter_linux.h>

#include <atomic>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <thread>

#include "connection_listener.h"
#include "gamepad.h"

#define GAMEPADS_LINUX_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), gamepads_linux_plugin_get_type(), \
                              GamepadsLinuxPlugin))

struct _GamepadsLinuxPlugin {
  GObject parent_instance;
};

G_DEFINE_TYPE(GamepadsLinuxPlugin, gamepads_linux_plugin, g_object_get_type())

static FlMethodChannel* channel;

namespace {
// An open gamepad. Its reader thread holds it as well as [gamepads], so a
// disconnect can drop it from the registry while the thread is still inside a
// read or a callback.
struct Connection {
  Connection(std::string id, gamepad::GamepadInfo info)
      : id(std::move(id)), info(std::move(info)) {}

  // What Dart knows the gamepad by. The next gamepad plugged in can take over
  // the device path, but never this id, so nothing the app cached for an
  // earlier gamepad (its axis layout, its button mapping) is applied to it.
  const std::string id;
  const gamepad::GamepadInfo info;
  // Cleared by a disconnect. The reader thread stops at its next event.
  std::atomic<bool> alive{true};
};
}  // namespace

bool keep_reading_events = false;
// Numbers each connection's id. Only the connection listener's thread uses it.
static unsigned long connection_count = 0;
// Changed by the connection listener's thread and the reader threads, and
// read by `listGamepads` on the main thread.
static std::mutex gamepads_mutex;
static std::map<std::string, std::shared_ptr<Connection>> gamepads = {};

// Null for anything but a button or an axis.
static const char* parse_event_type(const js_event& event) {
  switch (event.type & ~JS_EVENT_INIT) {
    case JS_EVENT_BUTTON:
      return "button";
    case JS_EVENT_AXIS:
      return "analog";
    default:
      return nullptr;
  }
}

static void free_gamepad_event(gpointer event) {
  fl_value_unref(static_cast<FlValue*>(event));
}

static gboolean send_gamepad_event(gpointer event) {
  if (channel) {
    fl_method_channel_invoke_method(channel, "onGamepadEvent",
                                    static_cast<FlValue*>(event), nullptr,
                                    nullptr, nullptr);
  }
  return G_SOURCE_REMOVE;
}

// Runs on the gamepad's reader thread. The embedder's API is not thread-safe,
// so the event is sent from the main loop, in the order it was read.
static void emit_gamepad_event(const Connection& connection,
                               const js_event& event) {
  const char* type = parse_event_type(event);
  if (type == nullptr) {
    // Thrown, this would end the whole process from a detached thread.
    std::cerr << "Unknown event type " << static_cast<int>(event.type)
              << std::endl;
    return;
  }
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(map, "gamepadId",
                           fl_value_new_string(connection.id.c_str()));
  fl_value_set_string_take(map, "time", fl_value_new_int(event.time));
  fl_value_set_string_take(map, "type", fl_value_new_string(type));
  fl_value_set_string_take(
      map, "key", fl_value_new_string(std::to_string(event.number).c_str()));
  fl_value_set_string_take(map, "value", fl_value_new_float(event.value));
  g_idle_add_full(G_PRIORITY_DEFAULT, send_gamepad_event, map,
                  free_gamepad_event);
}

static void respond_not_found(FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  fl_method_call_respond(method_call, response, nullptr);
}

static void respond(FlMethodCall* method_call, FlValue* value) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  fl_method_call_respond(method_call, response, nullptr);
}

static void gamepads_linux_plugin_handle_method_call(
    GamepadsLinuxPlugin* self,
    FlMethodCall* method_call) {
  const gchar* method = fl_method_call_get_name(method_call);

  if (strcmp(method, "listGamepads") == 0) {
    g_autoptr(FlValue) list = fl_value_new_list();
    std::lock_guard<std::mutex> lock(gamepads_mutex);
    for (const auto& [device_id, connection] : gamepads) {
      const gamepad::GamepadInfo& gamepad = connection->info;
      g_autoptr(FlValue) map = fl_value_new_map();
      fl_value_set(map, fl_value_new_string("id"),
                   fl_value_new_string(connection->id.c_str()));
      fl_value_set(map, fl_value_new_string("name"),
                   fl_value_new_string(gamepad.name.c_str()));
      
      // Agregar información extendida del sistema
      g_autoptr(FlValue) system_info = fl_value_new_map();
      fl_value_set(system_info, fl_value_new_string("connectionType"),
                   fl_value_new_string(gamepad.connection_type.c_str()));
      fl_value_set(system_info, fl_value_new_string("driver"),
                   fl_value_new_string(gamepad.driver_type.c_str()));
      fl_value_set(system_info, fl_value_new_string("vendorId"),
                   fl_value_new_string(gamepad.vendor_id.c_str()));
      fl_value_set(system_info, fl_value_new_string("productId"),
                   fl_value_new_string(gamepad.product_id.c_str()));
      fl_value_set(system_info, fl_value_new_string("hardwareId"),
                   fl_value_new_string(gamepad.hardware_id.c_str()));
      fl_value_set(system_info, fl_value_new_string("buttonCount"),
                   fl_value_new_int(gamepad.button_count));
      fl_value_set(system_info, fl_value_new_string("axisCount"),
                   fl_value_new_int(gamepad.axis_count));
      FlValue* axis_map = fl_value_new_list();
      for (int code : gamepad.axis_map) {
        fl_value_append_take(axis_map, fl_value_new_int(code));
      }
      fl_value_set_string_take(system_info, "axisMap", axis_map);

      fl_value_set(map, fl_value_new_string("systemInfo"), system_info);
      fl_value_append(list, map);
    }
    respond(method_call, list);
  } else {
    respond_not_found(method_call);
  }
}

static void method_call_cb([[maybe_unused]] FlMethodChannel* flutter_channel,
                           FlMethodCall* method_call,
                           gpointer user_data) {
  GamepadsLinuxPlugin* plugin = GAMEPADS_LINUX_PLUGIN(user_data);
  gamepads_linux_plugin_handle_method_call(plugin, method_call);
}

void gamepads_linux_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  GamepadsLinuxPlugin* plugin = GAMEPADS_LINUX_PLUGIN(
      g_object_new(gamepads_linux_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  channel = fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                                  "xyz.luan/gamepads", FL_METHOD_CODEC(codec));

  fl_method_channel_set_method_call_handler(
      channel, method_call_cb, g_object_ref(plugin), g_object_unref);

  g_object_unref(plugin);
}

// The gamepad's reader thread. Holding [connection] keeps it valid until the
// thread ends, however soon a disconnect drops it from the registry.
static void process_connection_event(std::shared_ptr<Connection> connection) {
  gamepad::listen(connection->info, connection->alive,
                  [&connection](const js_event& value) {
                    emit_gamepad_event(*connection, value);
                  });
  // A failed read can end the thread before the disconnect is seen. The
  // gamepad is gone either way, unless it has already been reconnected.
  std::lock_guard<std::mutex> lock(gamepads_mutex);
  auto entry = gamepads.find(connection->info.device_id);
  if (entry != gamepads.end() && entry->second == connection) {
    gamepads.erase(entry);
  }
}

void event_loop_start() {
  try {
    connection_listener::listen(
        &keep_reading_events,
        [](const connection_listener::ConnectionEvent& event) {
          std::string key = event.device_id;
          if (event.type == connection_listener::ConnectionEventType::CONNECTED) {
            {
              std::lock_guard<std::mutex> lock(gamepads_mutex);
              auto existing = gamepads.find(key);
              if (existing != gamepads.end() && existing->second->alive) {
                std::cout << "Existing gamepad found; skipping" << std::endl;
                return;
              }
            }

            std::optional<gamepad::GamepadInfo> info =
                gamepad::get_gamepad_info(key);
            if (!info) {
              std::cerr << "Unable to open joystick for reading " << key
                        << std::endl;
              return;
            }

            std::cout << "Gamepad connected " << key << " - " << info->name
                      << std::endl;
            auto connection = std::make_shared<Connection>(
                key + "#" + std::to_string(++connection_count),
                std::move(*info));
            {
              std::lock_guard<std::mutex> lock(gamepads_mutex);
              gamepads[key] = connection;
            }

            std::thread input_thread(process_connection_event, connection);
            input_thread.detach();
          } else {
            std::cout << "Gamepad disconnected " << key << std::endl;
            std::lock_guard<std::mutex> lock(gamepads_mutex);
            auto existing = gamepads.find(key);
            if (existing != gamepads.end()) {
              existing->second->alive = false;
              gamepads.erase(existing);
            }
          }
        });
  } catch (const std::exception& e) {
    std::cerr << "Gamepad event loop failed: " << e.what() << std::endl;
  } catch (...) {
    std::cerr << "Gamepad event loop failed with unknown error" << std::endl;
  }
}

static void gamepads_linux_plugin_dispose(GObject* object) {
  keep_reading_events = false;
  G_OBJECT_CLASS(gamepads_linux_plugin_parent_class)->dispose(object);
}

static void gamepads_linux_plugin_class_init(GamepadsLinuxPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = gamepads_linux_plugin_dispose;
}

static void gamepads_linux_plugin_init(GamepadsLinuxPlugin* self) {
  keep_reading_events = true;

  std::thread event_loop_thread(event_loop_start);
  event_loop_thread.detach();
}
