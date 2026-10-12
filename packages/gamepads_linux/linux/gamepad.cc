#include <fcntl.h>
#include <linux/joystick.h>
#include <unistd.h>
#include <cstdio>
#include <sys/stat.h>

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <functional>
#include <iostream>
#include <string>
#include <fstream>
#include <sstream>

#include "gamepad.h"
#include "utils.h"

using namespace gamepad;

/**
 * Reads a joystick event from the joystick gamepad_id.
 *
 * Returns 0 on success. Otherwise -1 is returned.
 */
static int read_event(int fd, struct js_event* event) {
  ssize_t bytes;

  do {
    bytes = read(fd, event, sizeof(*event));
  } while (bytes < 0 && errno == EINTR);

  if (bytes == sizeof(*event)) {
    return 0;
  }

  /* Error, could not read full event. */
  return -1;
}

namespace gamepad {
std::optional<GamepadInfo> get_gamepad_info(const std::string& device_id) {
  std::cout << "Listening to gamepad " << device_id << std::endl;

  int file_descriptor = open(device_id.c_str(), O_RDONLY);
  if (file_descriptor == -1) {
    std::cerr << "Could not open joystick: " << file_descriptor << std::endl;
    return std::nullopt;
  }

  char name[128];
  if (ioctl(file_descriptor, JSIOCGNAME(sizeof(name)), name) < 0) {
    std::cerr << "Failed to get joystick name: " << strerror(errno)
              << std::endl;
    strcpy(name, "Unknown");
  }

  // Obtener información extendida del dispositivo
  std::string connection_type = detect_connection_type(device_id);
  auto vendor_product = get_vendor_product_id(device_id);
  std::string hardware_id = get_hardware_id(device_id);
  auto button_axis_count = get_button_axis_count(file_descriptor);
  
  return {{
    device_id, 
    name, 
    file_descriptor, 
    connection_type,
    "evdev",  // Driver type en Linux
    vendor_product.first,
    vendor_product.second,
    hardware_id,
    button_axis_count.first,
    button_axis_count.second,
    get_axis_map(file_descriptor, button_axis_count.second),
  }};
}

void listen(const GamepadInfo& gamepad,
            const std::atomic<bool>& alive,
            const std::function<void(const js_event&)>& event_consumer) {
  std::cout << "Listening to gamepad " << gamepad.device_id << std::endl;

  while (alive) {
    struct js_event event;
    // Unplugging fails the read (ENODEV) rather than blocking it, so this ends
    // whether or not the disconnect has been seen yet. A failed read leaves
    // [event] unset, so it must never reach the consumer.
    if (read_event(gamepad.file_descriptor, &event) != 0) {
      break;
    }
    event_consumer(event);
  }

  std::cout << "Stopped listening for events: " << gamepad.device_id
            << std::endl;
  close(gamepad.file_descriptor);
}

// Detectar tipo de conexión analizando el hardware ID y subsystem
std::string detect_connection_type(const std::string& device_path) {
  // Extraer el nombre del dispositivo (ej: js0 de /dev/input/js0)
  std::string device_name = device_path.substr(device_path.rfind('/') + 1);
  
  // MÉTODO 1: Analizar el hardware ID (más confiable)
  std::string hardware_id = get_hardware_id(device_path);
  if (hardware_id != "unknown") {
    // Buscar bus type en el hardware ID
    // Formato: input:bXXXXvYYYYpZZZZ donde XXXX es el bus type
    size_t bus_pos = hardware_id.find("b");
    if (bus_pos != std::string::npos && bus_pos + 5 < hardware_id.length()) {
      std::string bus_type = hardware_id.substr(bus_pos + 1, 4);
      
      if (bus_type == "0005") {
        return "bluetooth";  // Bus type 5 = Bluetooth
      } else if (bus_type == "0003") {
        return "usb";        // Bus type 3 = USB
      } else if (bus_type == "0019") {
        return "wireless";   // Bus type 25 = Host (wireless 2.4GHz)
      }
    }
  }
  
  // MÉTODO 2: Analizar el subsystem
  std::string sys_path = "/sys/class/input/" + device_name + "/device/subsystem";
  
  char buffer[256];
  ssize_t len = readlink(sys_path.c_str(), buffer, sizeof(buffer) - 1);
  
  if (len != -1) {
    buffer[len] = '\0';
    std::string subsystem = buffer;
    
    if (subsystem.find("bluetooth") != std::string::npos) {
      return "bluetooth";
    } else if (subsystem.find("usb") != std::string::npos) {
      return "usb";
    } else if (subsystem.find("platform") != std::string::npos) {
      return "wireless";
    }
  }
  
  // MÉTODO 3: Analizar el parent device path
  std::string parent_path = "/sys/class/input/" + device_name + "/device/phys";
  std::ifstream phys_file(parent_path);
  if (phys_file.is_open()) {
    std::string line;
    if (std::getline(phys_file, line)) {
      if (line.find("bluetooth") != std::string::npos || line.find("hci") != std::string::npos) {
        return "bluetooth";
      } else if (line.find("usb") != std::string::npos) {
        return "usb";
      }
    }
    phys_file.close();
  }
  
  // Fallback: usar wireless como default (no js0/js1 porque no es confiable)
  return "wireless";
}

// Obtener VID/PID desde sysfs
std::pair<std::string, std::string> get_vendor_product_id(const std::string& device_path) {
  std::string vendor_id = "unknown";
  std::string product_id = "unknown";
  
  std::string device_name = device_path.substr(device_path.rfind('/') + 1);
  
  // Intentar leer desde sysfs
  std::string vendor_path = "/sys/class/input/" + device_name + "/device/id/vendor";
  std::string product_path = "/sys/class/input/" + device_name + "/device/id/product";
  
  std::ifstream vendor_file(vendor_path);
  if (vendor_file.is_open()) {
    std::string line;
    if (std::getline(vendor_file, line)) {
      // Convertir de decimal a hex
      int vendor_int = std::stoi(line, nullptr, 16);
      std::stringstream ss;
      ss << std::hex << std::uppercase << vendor_int;
      vendor_id = ss.str();
    }
    vendor_file.close();
  }
  
  std::ifstream product_file(product_path);
  if (product_file.is_open()) {
    std::string line;
    if (std::getline(product_file, line)) {
      // Convertir de decimal a hex
      int product_int = std::stoi(line, nullptr, 16);
      std::stringstream ss;
      ss << std::hex << std::uppercase << product_int;
      product_id = ss.str();
    }
    product_file.close();
  }
  
  return {vendor_id, product_id};
}

// Obtener Hardware ID desde uevent
std::string get_hardware_id(const std::string& device_path) {
  std::string device_name = device_path.substr(device_path.rfind('/') + 1);
  std::string uevent_path = "/sys/class/input/" + device_name + "/device/uevent";
  
  std::ifstream uevent_file(uevent_path);
  if (uevent_file.is_open()) {
    std::string line;
    while (std::getline(uevent_file, line)) {
      if (line.find("MODALIAS=") == 0) {
        return line.substr(9); // Remover "MODALIAS="
      }
    }
    uevent_file.close();
  }
  
  return "unknown";
}

// Obtener número de botones y ejes usando ioctl
std::pair<int, int> get_button_axis_count(int fd) {
  __u8 num_buttons = 0;
  __u8 num_axes = 0;
  
  if (ioctl(fd, JSIOCGBUTTONS, &num_buttons) < 0) {
    num_buttons = 0;
  }
  
  if (ioctl(fd, JSIOCGAXES, &num_axes) < 0) {
    num_axes = 0;
  }
  
  return {static_cast<int>(num_buttons), static_cast<int>(num_axes)};
}

std::vector<int> get_axis_map(int fd, int axis_count) {
  __u8 codes[ABS_CNT];
  if (ioctl(fd, JSIOCGAXMAP, codes) < 0) {
    return {};
  }
  return std::vector<int>(codes, codes + std::min(axis_count, ABS_CNT));
}

}  // namespace gamepad