package deckreel

import (
	"encoding/binary"
	"fmt"
	"math"
)

const SampleRate = 48000

// PCM accepts the mono PCM16 RIFF/WAVE output requested from VOICEVOX.
func PCM(wav []byte) ([]byte, error) {
	if len(wav) < 12 || string(wav[:4]) != "RIFF" || string(wav[8:12]) != "WAVE" {
		return nil, fmt.Errorf("VOICEVOX returned invalid WAV")
	}
	if uint64(binary.LittleEndian.Uint32(wav[4:8]))+8 != uint64(len(wav)) {
		return nil, fmt.Errorf("truncated WAV")
	}
	var pcm []byte
	valid := false
	for off := 12; off+8 <= len(wav); {
		n := int(binary.LittleEndian.Uint32(wav[off+4 : off+8]))
		off += 8
		if n > len(wav)-off {
			return nil, fmt.Errorf("truncated WAV chunk")
		}
		switch string(wav[off-8 : off-4]) {
		case "fmt ":
			if n < 16 {
				return nil, fmt.Errorf("invalid WAV format")
			}
			f := wav[off:]
			valid = binary.LittleEndian.Uint16(f) == 1 && binary.LittleEndian.Uint16(f[2:]) == 1 && binary.LittleEndian.Uint32(f[4:]) == SampleRate && binary.LittleEndian.Uint16(f[14:]) == 16
		case "data":
			pcm = wav[off : off+n]
		}
		off += n + (n % 2)
	}
	if !valid || len(pcm) == 0 || len(pcm)%2 != 0 {
		return nil, fmt.Errorf("expected nonempty 48kHz mono PCM16 WAV")
	}
	return pcm, nil
}
func WAV(pcm []byte) []byte {
	b := make([]byte, 44+len(pcm))
	copy(b, "RIFF")
	binary.LittleEndian.PutUint32(b[4:], uint32(len(b)-8))
	copy(b[8:], "WAVEfmt ")
	binary.LittleEndian.PutUint32(b[16:], 16)
	binary.LittleEndian.PutUint16(b[20:], 1)
	binary.LittleEndian.PutUint16(b[22:], 1)
	binary.LittleEndian.PutUint32(b[24:], SampleRate)
	binary.LittleEndian.PutUint32(b[28:], SampleRate*2)
	binary.LittleEndian.PutUint16(b[32:], 2)
	binary.LittleEndian.PutUint16(b[34:], 16)
	copy(b[36:], "data")
	binary.LittleEndian.PutUint32(b[40:], uint32(len(pcm)))
	copy(b[44:], pcm)
	return b
}
func Frames(samples int, seconds float64) int {
	return int(math.Ceil((float64(samples) + seconds*SampleRate) / 1600))
}
func PadPCM(pcm []byte, frames int) []byte {
	b := make([]byte, frames*1600*2)
	copy(b, pcm)
	return WAV(b)
}
