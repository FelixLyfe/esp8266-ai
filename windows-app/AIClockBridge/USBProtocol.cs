namespace AIClockBridge;

enum USBMessage : byte
{
    Hello = 0x01,
    HelloAck = 0x02,
    Heartbeat = 0x03,
    HeartbeatAck = 0x04,
    Status = 0x10,
    Clock = 0x13,
    GetInfo = 0x20,
    DeviceInfo = 0x21,
    Command = 0x22,
    GetResource = 0x23,
    ResourceBegin = 0x30,
    ResourceChunk = 0x31,
    ResourceEnd = 0x32,
    Ack = 0x7E,
}

enum USBResource : byte
{
    ClaudeGif = 3,
    CodexGif = 4,
    ClaudeSprite = 5,
    CodexSprite = 6,
}

readonly record struct USBFrame(USBMessage Type, ushort Sequence, byte[] Payload)
{
    public const byte Magic0 = 0xA5;
    public const byte Magic1 = 0x5A;
    public const byte Version = 1;
    public const int MaxPayload = 1024;

    public byte[] Encode()
    {
        if (Payload.Length > MaxPayload) throw new ArgumentOutOfRangeException(nameof(Payload));
        var result = new byte[8 + Payload.Length + 4];
        result[0] = Magic0;
        result[1] = Magic1;
        result[2] = Version;
        result[3] = (byte)Type;
        WriteUInt16(result, 4, Sequence);
        WriteUInt16(result, 6, (ushort)Payload.Length);
        Payload.CopyTo(result, 8);
        WriteUInt32(result, 8 + Payload.Length, Crc32(result.AsSpan(2, 6 + Payload.Length)));
        return result;
    }

    public static bool TryDecode(List<byte> buffer, out USBFrame frame)
    {
        frame = default;
        while (buffer.Count >= 2 && (buffer[0] != Magic0 || buffer[1] != Magic1)) buffer.RemoveAt(0);
        if (buffer.Count < 8) return false;
        if (buffer[2] != Version || !Enum.IsDefined(typeof(USBMessage), buffer[3]))
        {
            buffer.RemoveAt(0);
            return TryDecode(buffer, out frame);
        }
        var length = buffer[6] | (buffer[7] << 8);
        if (length > MaxPayload)
        {
            buffer.RemoveAt(0);
            return TryDecode(buffer, out frame);
        }
        var total = 8 + length + 4;
        if (buffer.Count < total) return false;
        var candidate = buffer.GetRange(0, total).ToArray();
        var expected = ReadUInt32(candidate, 8 + length);
        var actual = Crc32(candidate.AsSpan(2, 6 + length));
        if (expected != actual)
        {
            buffer.RemoveAt(0);
            return TryDecode(buffer, out frame);
        }
        var payload = new byte[length];
        Array.Copy(candidate, 8, payload, 0, length);
        frame = new USBFrame((USBMessage)candidate[3], ReadUInt16(candidate, 4), payload);
        buffer.RemoveRange(0, total);
        return true;
    }

    public static uint Crc32(ReadOnlySpan<byte> bytes)
    {
        uint crc = 0xFFFF_FFFF;
        foreach (var value in bytes)
        {
            crc ^= value;
            for (var bit = 0; bit < 8; bit++)
                crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB8_8320u : 0u);
        }
        return crc ^ 0xFFFF_FFFF;
    }

    public static ushort ReadUInt16(IReadOnlyList<byte> data, int offset) =>
        (ushort)(data[offset] | (data[offset + 1] << 8));

    public static uint ReadUInt32(IReadOnlyList<byte> data, int offset) =>
        (uint)(data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16)
               | (data[offset + 3] << 24));

    public static void WriteUInt16(IList<byte> data, int offset, ushort value)
    {
        data[offset] = (byte)value;
        data[offset + 1] = (byte)(value >> 8);
    }

    public static void WriteUInt32(IList<byte> data, int offset, uint value)
    {
        data[offset] = (byte)value;
        data[offset + 1] = (byte)(value >> 8);
        data[offset + 2] = (byte)(value >> 16);
        data[offset + 3] = (byte)(value >> 24);
    }
}
