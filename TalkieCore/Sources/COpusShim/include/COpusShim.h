#ifndef COPUS_SHIM_H
#define COPUS_SHIM_H

#include <stdint.h>

/*
 * Non-variadic wrappers around libopus.
 *
 * Swift cannot call C variadic functions, and libopus configures everything
 * through `opus_encoder_ctl(enc, request, ...)`. This shim exposes the handful of
 * operations Talkie actually needs as ordinary functions.
 *
 * Handles are `void *` so this header stays free of any opus include, which keeps
 * the framework's module map out of the Swift side entirely.
 */

#ifdef __cplusplus
extern "C" {
#endif

/* Creates an encoder configured for OPUS_APPLICATION_VOIP. */
void *talkie_opus_encoder_create(int32_t sample_rate, int32_t channels, int32_t *out_error);
void talkie_opus_encoder_destroy(void *encoder);

/*
 * Applies every encoder setting in one call. `inband_fec` and `dtx` are booleans,
 * `packet_loss_perc` is 0-100, `complexity` is 0-10.
 * Returns 0 on success, or the first opus error encountered.
 */
int32_t talkie_opus_encoder_configure(void *encoder,
                                      int32_t bitrate,
                                      int32_t inband_fec,
                                      int32_t packet_loss_perc,
                                      int32_t dtx,
                                      int32_t complexity);

/* Returns encoded byte count, or a negative opus error. */
int32_t talkie_opus_encode(void *encoder,
                           const int16_t *pcm,
                           int32_t frame_size,
                           uint8_t *output,
                           int32_t max_output);

void *talkie_opus_decoder_create(int32_t sample_rate, int32_t channels, int32_t *out_error);
void talkie_opus_decoder_destroy(void *decoder);

/*
 * Returns decoded sample count, or a negative opus error.
 *
 * Three modes:
 *   normal   - data != NULL, length > 0, decode_fec = 0
 *   conceal  - data == NULL, length = 0, decode_fec = 0  (packet-loss concealment)
 *   recover  - data = the NEXT packet, decode_fec = 1    (in-band FEC)
 */
int32_t talkie_opus_decode(void *decoder,
                           const uint8_t *data,
                           int32_t length,
                           int16_t *pcm,
                           int32_t frame_size,
                           int32_t decode_fec);

/*
 * 1 when the packet carries an LBRR (in-band FEC) copy of the previous frame.
 *
 * Needed because opus_decode with decode_fec=1 silently falls back to plain
 * concealment when there is no FEC copy present, and returns a full frame either
 * way - so without asking first, a "recovered by FEC" count cannot be told apart
 * from ordinary loss.
 */
int32_t talkie_opus_packet_has_lbrr(const uint8_t *data, int32_t length);

const char *talkie_opus_error_string(int32_t error);

#ifdef __cplusplus
}
#endif

#endif /* COPUS_SHIM_H */
