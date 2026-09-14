#include "COpusShim.h"

#include <stddef.h>

#include <opus/opus.h>

void *talkie_opus_encoder_create(int32_t sample_rate, int32_t channels, int32_t *out_error) {
	int error = OPUS_OK;
	OpusEncoder *encoder = opus_encoder_create((opus_int32)sample_rate, (int)channels,
	                                           OPUS_APPLICATION_VOIP, &error);
	if (out_error) { *out_error = (int32_t)error; }
	return (error == OPUS_OK) ? encoder : NULL;
}

void talkie_opus_encoder_destroy(void *encoder) {
	if (encoder) { opus_encoder_destroy((OpusEncoder *)encoder); }
}

int32_t talkie_opus_encoder_configure(void *encoder,
                                      int32_t bitrate,
                                      int32_t inband_fec,
                                      int32_t packet_loss_perc,
                                      int32_t dtx,
                                      int32_t complexity) {
	OpusEncoder *enc = (OpusEncoder *)encoder;
	if (!enc) { return OPUS_BAD_ARG; }

	int result;
	result = opus_encoder_ctl(enc, OPUS_SET_BITRATE_REQUEST, (opus_int32)bitrate);
	if (result != OPUS_OK) { return (int32_t)result; }

	result = opus_encoder_ctl(enc, OPUS_SET_INBAND_FEC_REQUEST, (opus_int32)inband_fec);
	if (result != OPUS_OK) { return (int32_t)result; }

	result = opus_encoder_ctl(enc, OPUS_SET_PACKET_LOSS_PERC_REQUEST, (opus_int32)packet_loss_perc);
	if (result != OPUS_OK) { return (int32_t)result; }

	result = opus_encoder_ctl(enc, OPUS_SET_DTX_REQUEST, (opus_int32)dtx);
	if (result != OPUS_OK) { return (int32_t)result; }

	result = opus_encoder_ctl(enc, OPUS_SET_COMPLEXITY_REQUEST, (opus_int32)complexity);
	if (result != OPUS_OK) { return (int32_t)result; }

	/* Voice-tuned mode selection; this is a speech link, never music. */
	result = opus_encoder_ctl(enc, OPUS_SET_SIGNAL_REQUEST, (opus_int32)OPUS_SIGNAL_VOICE);
	return (int32_t)result;
}

int32_t talkie_opus_encode(void *encoder,
                           const int16_t *pcm,
                           int32_t frame_size,
                           uint8_t *output,
                           int32_t max_output) {
	if (!encoder || !pcm || !output) { return OPUS_BAD_ARG; }
	return (int32_t)opus_encode((OpusEncoder *)encoder, (const opus_int16 *)pcm,
	                            (int)frame_size, output, (opus_int32)max_output);
}

void *talkie_opus_decoder_create(int32_t sample_rate, int32_t channels, int32_t *out_error) {
	int error = OPUS_OK;
	OpusDecoder *decoder = opus_decoder_create((opus_int32)sample_rate, (int)channels, &error);
	if (out_error) { *out_error = (int32_t)error; }
	return (error == OPUS_OK) ? decoder : NULL;
}

void talkie_opus_decoder_destroy(void *decoder) {
	if (decoder) { opus_decoder_destroy((OpusDecoder *)decoder); }
}

int32_t talkie_opus_decode(void *decoder,
                           const uint8_t *data,
                           int32_t length,
                           int16_t *pcm,
                           int32_t frame_size,
                           int32_t decode_fec) {
	if (!decoder || !pcm) { return OPUS_BAD_ARG; }
	return (int32_t)opus_decode((OpusDecoder *)decoder, data, (opus_int32)length,
	                            (opus_int16 *)pcm, (int)frame_size, (int)decode_fec);
}

int32_t talkie_opus_packet_has_lbrr(const uint8_t *data, int32_t length) {
	if (!data || length <= 0) { return 0; }
	return (int32_t)opus_packet_has_lbrr(data, (opus_int32)length);
}

const char *talkie_opus_error_string(int32_t error) {
	return opus_strerror((int)error);
}
