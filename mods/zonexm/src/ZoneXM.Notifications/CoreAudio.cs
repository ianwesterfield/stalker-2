using System.Runtime.InteropServices;

namespace ZoneXM.Notifications;

internal interface IAudioSession : IDisposable
{
    string Id { get; }
    int ProcessId { get; }
    float Volume { get; set; }
}

internal sealed class CoreAudioSession(string id, int processId, nint volume) : IAudioSession
{
    private nint pointer = volume;
    public string Id { get; } = id;
    public int ProcessId { get; } = processId;
    public float Volume
    {
        get
        {
            Marshal.ThrowExceptionForHR(CoreAudio.Method<CoreAudio.GetVolume>(pointer, 4)(pointer, out var value));
            return value;
        }
        set
        {
            var context = Guid.Empty;
            Marshal.ThrowExceptionForHR(CoreAudio.Method<CoreAudio.SetVolume>(pointer, 3)(pointer, value, ref context));
        }
    }
    public void Dispose()
    {
        if (pointer != 0) Marshal.Release(pointer);
        pointer = 0;
    }
}

internal static class CoreAudio
{
    private static readonly Guid EnumeratorClass = new("BCDE0395-E52F-467C-8E3D-C4579291692E");
    private static readonly Guid EnumeratorInterface = new("A95664D2-9614-4F35-A746-DE8DB63617E6");
    private static readonly Guid ManagerInterface = new("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F");
    private static readonly Guid ControlInterface = new("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d");
    private static readonly Guid VolumeInterface = new("87CE5498-68D6-44E5-9215-6DA47EF883D8");

    [DllImport("ole32.dll")] internal static extern int CoInitializeEx(nint reserved, uint mode);
    [DllImport("ole32.dll")] internal static extern void CoUninitialize();
    [DllImport("ole32.dll")] private static extern int CoCreateInstance(in Guid clsid, nint outer,
        uint context, in Guid iid, out nint instance);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int GetEndpoint(nint self, int flow, int role, out nint device);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int Activate(nint self, ref Guid iid, int context, nint parameters, out nint manager);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int GetEnumerator(nint self, out nint enumerator);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int GetCount(nint self, out int count);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int GetSession(nint self, int index, out nint control);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int GetInt(nint self, out int value);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int GetString(nint self, out nint value);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] internal delegate int GetVolume(nint self, out float value);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] internal delegate int SetVolume(nint self, float value, ref Guid context);

    // Same raw-vtable interop as the proven PowerShell watchdog, with explicit ownership.
    internal static T Method<T>(nint instance, int slot) where T : Delegate =>
        Marshal.GetDelegateForFunctionPointer<T>(Marshal.ReadIntPtr(Marshal.ReadIntPtr(instance), slot * nint.Size));

    private static nint Query(nint instance, Guid iid)
    {
        Marshal.ThrowExceptionForHR(Marshal.QueryInterface(instance, in iid, out var result));
        return result;
    }

    internal static List<IAudioSession> Sessions()
    {
        var result = new List<IAudioSession>();
        nint enumerator = 0, device = 0, manager = 0, sessions = 0;
        try
        {
            Marshal.ThrowExceptionForHR(CoCreateInstance(in EnumeratorClass, 0, 23, in EnumeratorInterface, out enumerator));
            Marshal.ThrowExceptionForHR(Method<GetEndpoint>(enumerator, 4)(enumerator, 0, 0, out device));
            var iid = ManagerInterface;
            Marshal.ThrowExceptionForHR(Method<Activate>(device, 3)(device, ref iid, 23, 0, out manager));
            Marshal.ThrowExceptionForHR(Method<GetEnumerator>(manager, 5)(manager, out sessions));
            Marshal.ThrowExceptionForHR(Method<GetCount>(sessions, 3)(sessions, out var count));
            for (var index = 0; index < count; index++)
            {
                nint control = 0, extended = 0, volume = 0, identifier = 0;
                try
                {
                    Marshal.ThrowExceptionForHR(Method<GetSession>(sessions, 4)(sessions, index, out control));
                    Marshal.ThrowExceptionForHR(Method<GetInt>(control, 3)(control, out var state));
                    if (state == 2) continue; // expired session
                    extended = Query(control, ControlInterface);
                    Marshal.ThrowExceptionForHR(Method<GetInt>(extended, 14)(extended, out var pid));
                    if (pid == 0) continue; // Windows system sounds
                    Marshal.ThrowExceptionForHR(Method<GetString>(extended, 13)(extended, out identifier));
                    var id = Marshal.PtrToStringUni(identifier) ?? throw new InvalidOperationException("Audio session has no instance ID");
                    volume = Query(control, VolumeInterface);
                    result.Add(new CoreAudioSession(id, pid, volume));
                    volume = 0;
                }
                finally
                {
                    if (identifier != 0) Marshal.FreeCoTaskMem(identifier);
                    if (volume != 0) Marshal.Release(volume);
                    if (extended != 0) Marshal.Release(extended);
                    if (control != 0) Marshal.Release(control);
                }
            }
            return result;
        }
        catch
        {
            foreach (var session in result) session.Dispose();
            throw;
        }
        finally
        {
            if (sessions != 0) Marshal.Release(sessions);
            if (manager != 0) Marshal.Release(manager);
            if (device != 0) Marshal.Release(device);
            if (enumerator != 0) Marshal.Release(enumerator);
        }
    }
}
