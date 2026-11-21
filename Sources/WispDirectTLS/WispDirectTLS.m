// SPDX-License-Identifier: GPL-3.0-or-later
#include "WispDirectTLS.h"

void wisp_set_direct_key(sec_protocol_options_t options, const void *key, size_t length) {
    static const char identity[] = "wisp-direct-v1";
    dispatch_data_t secret = dispatch_data_create(key, length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    dispatch_data_t name = dispatch_data_create(identity, sizeof(identity) - 1, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    sec_protocol_options_add_pre_shared_key(options, secret, name);
    sec_protocol_options_append_tls_ciphersuite(options, (tls_ciphersuite_t)0x00A8); // TLS_PSK_WITH_AES_128_GCM_SHA256
#if !__has_feature(objc_arc)
    dispatch_release(secret);
    dispatch_release(name);
#endif
}
