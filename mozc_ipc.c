#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  mach_msg_header_t header;
  mach_msg_body_t body;
  mach_msg_ool_descriptor_t data;
  mach_msg_type_number_t count;
} mozc_mach_message;

typedef struct {
  mach_msg_header_t header;
  mach_msg_body_t body;
  mach_msg_ool_descriptor_t data;
  mach_msg_type_number_t count;
  mach_msg_trailer_t trailer;
} mozc_mach_receive_message;

static int read_varint(const uint8_t *data, size_t length, size_t *offset, uint64_t *value) {
  uint64_t result = 0;
  for (int i = 0; i < 10; ++i) {
    if (*offset >= length) return 0;
    uint8_t byte = data[(*offset)++];
    result |= ((uint64_t)(byte & 0x7f)) << (7 * i);
    if (!(byte & 0x80)) { *value = result; return 1; }
  }
  return 0;
}

static int skip_field(const uint8_t *data, size_t length, size_t *offset, uint64_t wire_type) {
  uint64_t ignored, size;
  switch (wire_type) {
    case 0: return read_varint(data, length, offset, &ignored);
    case 1: if (*offset + 8 > length) return 0; *offset += 8; return 1;
    case 2:
      if (!read_varint(data, length, offset, &size) || size > length - *offset) return 0;
      *offset += (size_t)size; return 1;
    case 5: if (*offset + 4 > length) return 0; *offset += 4; return 1;
    default: return 0;
  }
}

// .session.ipc is a small protobuf. Its field 4 is IPC_PROTOCOL_VERSION.
static int session_protocol_version(uint32_t *version) {
  const char *home = getenv("HOME");
  if (!home) return 0;
  char path[4096];
  if (snprintf(path, sizeof(path), "%s/Library/Application Support/Google/JapaneseInput/.session.ipc", home) >= (int)sizeof(path)) return 0;
  FILE *file = fopen(path, "rb");
  if (!file) return 0;
  uint8_t data[1024];
  size_t length = fread(data, 1, sizeof(data), file);
  fclose(file);
  size_t offset = 0;
  while (offset < length) {
    uint64_t key, value;
    if (!read_varint(data, length, &offset, &key)) return 0;
    if ((key >> 3) == 4 && (key & 7) == 0) {
      if (!read_varint(data, length, &offset, &value) || value > UINT32_MAX) return 0;
      *version = (uint32_t)value;
      return 1;
    }
    if (!skip_field(data, length, &offset, key & 7)) return 0;
  }
  return 0;
}

// Returns 0 on success. The caller owns *response and frees it with mozc_ipc_free.
int mozc_ipc_call(const uint8_t *request, size_t request_length, uint8_t **response, size_t *response_length) {
  if (!request || !response || !response_length || request_length == 0) return -1;
  *response = NULL;
  *response_length = 0;

  uint32_t protocol_version;
  if (!session_protocol_version(&protocol_version)) return -2;

  mach_port_t server_port = MACH_PORT_NULL;
  kern_return_t kr = bootstrap_look_up(bootstrap_port, "com.google.inputmethod.Japanese.Converter.session", &server_port);
  if (kr != KERN_SUCCESS) return -3;

  mach_port_t client_port = MACH_PORT_NULL;
  if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &client_port) != KERN_SUCCESS) return -4;

  uint8_t *request_copy = malloc(request_length);
  if (!request_copy) { mach_port_destroy(mach_task_self(), client_port); return -5; }
  memcpy(request_copy, request, request_length);

  mozc_mach_message send_message;
  memset(&send_message, 0, sizeof(send_message));
  send_message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND) | MACH_MSGH_BITS_COMPLEX;
  send_message.header.msgh_size = sizeof(send_message);
  send_message.header.msgh_remote_port = server_port;
  send_message.header.msgh_local_port = client_port;
  send_message.header.msgh_id = protocol_version;
  send_message.body.msgh_descriptor_count = 1;
  send_message.data.address = request_copy;
  send_message.data.size = (mach_msg_size_t)request_length;
  send_message.data.deallocate = false;
  send_message.data.copy = MACH_MSG_VIRTUAL_COPY;
  send_message.data.type = MACH_MSG_OOL_DESCRIPTOR;
  send_message.count = (mach_msg_type_number_t)request_length;

  kr = mach_msg(&send_message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, send_message.header.msgh_size, 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL);
  free(request_copy);
  if (kr != MACH_MSG_SUCCESS) { mach_port_destroy(mach_task_self(), client_port); return -6; }

  mozc_mach_receive_message receive_message;
  memset(&receive_message, 0, sizeof(receive_message));
  receive_message.header.msgh_size = sizeof(receive_message);
  kr = mach_msg(&receive_message.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, receive_message.header.msgh_size, client_port, 1000, MACH_PORT_NULL);
  if (kr != MACH_MSG_SUCCESS) { mach_port_destroy(mach_task_self(), client_port); return -7; }
  if (receive_message.header.msgh_id != protocol_version || receive_message.data.size == 0 || !receive_message.data.address) {
    mach_port_destroy(mach_task_self(), client_port); return -8;
  }
  uint8_t *copy = malloc(receive_message.data.size);
  if (!copy) { vm_deallocate(mach_task_self(), (vm_address_t)receive_message.data.address, receive_message.data.size); mach_port_destroy(mach_task_self(), client_port); return -9; }
  memcpy(copy, receive_message.data.address, receive_message.data.size);
  *response = copy;
  *response_length = receive_message.data.size;
  vm_deallocate(mach_task_self(), (vm_address_t)receive_message.data.address, receive_message.data.size);
  mach_port_destroy(mach_task_self(), client_port);
  return 0;
}

void mozc_ipc_free(uint8_t *pointer) { free(pointer); }
