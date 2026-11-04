#ifndef RUNNER_SECURE_UNLOCK_H_
#define RUNNER_SECURE_UNLOCK_H_
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <memory>

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateSecureUnlockChannel(flutter::BinaryMessenger* messenger);
#endif
