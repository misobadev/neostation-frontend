#include <fcntl.h>
#include <linux/joystick.h>
#include <unistd.h>

#include <atomic>
#include <functional>
#include <optional>
#include <string>
#include <vector>

#include "utils.h"

namespace gamepad {
struct GamepadInfo {
  std::string device_id;
  std::string name;
  int file_descriptor;
  std::string connection_type;
  std::string driver_type;
  std::string vendor_id;
  std::string product_id;
  std::string hardware_id;
  int button_count;
  int axis_count;
  // The ABS code of each axis index, as joydev numbers only the axes a pad
  // has. Empty when unknown.
  std::vector<int> axis_map;
};

std::optional<GamepadInfo> get_gamepad_info(const std::string& device);

std::string detect_connection_type(const std::string& device_path);
std::pair<std::string, std::string> get_vendor_product_id(const std::string& device_path);
std::string get_hardware_id(const std::string& device_path);
std::pair<int, int> get_button_axis_count(int fd);
std::vector<int> get_axis_map(int fd, int axis_count);

// Reads [gamepad]'s events until [alive] is cleared or a read fails, as one
// does once the device is unplugged, then closes its file descriptor.
void listen(const GamepadInfo& gamepad,
            const std::atomic<bool>& alive,
            const std::function<void(const js_event&)>& event_consumer);
}  // namespace gamepad