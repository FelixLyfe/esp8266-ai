using System.Text;
using AIClockBridge;

static void Require(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}

Require(USBFrame.Crc32(Encoding.ASCII.GetBytes("123456789")) == 0xCBF4_3926,
    "CRC32 reference vector failed");

var original = new USBFrame(USBMessage.Command, 0x1234, Encoding.UTF8.GetBytes("{\"display\":\"cpu\"}"));
var noisy = new List<byte> { 0x00, 0xFF, 0xA5 };
noisy.AddRange(original.Encode());
Require(USBFrame.TryDecode(noisy, out var decoded), "frame did not decode");
Require(decoded.Type == original.Type && decoded.Sequence == original.Sequence
        && decoded.Payload.SequenceEqual(original.Payload), "roundtrip mismatch");

var corrupt = new USBFrame(USBMessage.Heartbeat, 1, Array.Empty<byte>()).Encode();
corrupt[8] ^= 0x01;
var valid = new USBFrame(USBMessage.HeartbeatAck, 2, Array.Empty<byte>()).Encode();
var stream = corrupt.Concat(valid).ToList();
Require(USBFrame.TryDecode(stream, out decoded) && decoded.Type == USBMessage.HeartbeatAck,
    "decoder did not recover after corrupt frame");

Console.WriteLine("USB protocol smoke tests passed");
