using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace ZoneXM.Audio
{
    // Raw vtables avoid the COM interface casts unsupported by this PowerShell host.
    public static class AudioSessions
    {
        private static readonly Guid AudioSessionControlInterfaceId = new Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d");
        private static readonly Guid AudioSessionManagerInterfaceId = new Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F");
        private static readonly Guid DeviceEnumeratorClassId = new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E");
        private static readonly Guid DeviceEnumeratorInterfaceId = new Guid("A95664D2-9614-4F35-A746-DE8DB63617E6");
        private static readonly Guid SimpleAudioVolumeInterfaceId = new Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8");

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int Activate(IntPtr instance, ref Guid interfaceId, int classContext, IntPtr activationParameters, out IntPtr manager);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int GetCount(IntPtr instance, out int count);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int GetDefaultAudioEndpoint(IntPtr instance, int dataFlow, int role, out IntPtr device);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int GetMasterVolume(IntPtr instance, out float level);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int GetProcessId(IntPtr instance, out int processId);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int GetSession(IntPtr instance, int index, out IntPtr control);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int GetSessionEnumerator(IntPtr instance, out IntPtr enumerator);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int SetMasterVolume(IntPtr instance, float level, ref Guid context);

        private static TDelegate ReadVtable<TDelegate>(IntPtr instance, int slot) where TDelegate : Delegate
        {
            var vtable = Marshal.ReadIntPtr(instance);
            var function = Marshal.ReadIntPtr(vtable, slot * IntPtr.Size);

            return Marshal.GetDelegateForFunctionPointer<TDelegate>(function);
        }

        private static IntPtr QueryInterface(IntPtr instance, Guid interfaceId)
        {
            IntPtr result;

            return Marshal.QueryInterface(instance, in interfaceId, out result) == 0 ? result : IntPtr.Zero;
        }

        public static Dictionary<int, IntPtr> EnumerateVolumes()
        {
            var volumes = new Dictionary<int, IntPtr>();
            var nativeEnumerator = Activator.CreateInstance(Type.GetTypeFromCLSID(DeviceEnumeratorClassId));
            var unknown = Marshal.GetIUnknownForObject(nativeEnumerator);
            var enumerator = QueryInterface(unknown, DeviceEnumeratorInterfaceId);

            if (enumerator == IntPtr.Zero)
            {
                throw new COMException("QueryInterface IMMDeviceEnumerator failed");
            }

            IntPtr device;
            Marshal.ThrowExceptionForHR(ReadVtable<GetDefaultAudioEndpoint>(enumerator, 4)(enumerator, 0, 0, out device));

            IntPtr manager;
            var managerInterfaceId = AudioSessionManagerInterfaceId;
            Marshal.ThrowExceptionForHR(ReadVtable<Activate>(device, 3)(device, ref managerInterfaceId, 23, IntPtr.Zero, out manager));

            IntPtr sessionEnumerator;
            Marshal.ThrowExceptionForHR(ReadVtable<GetSessionEnumerator>(manager, 5)(manager, out sessionEnumerator));

            int count;
            Marshal.ThrowExceptionForHR(ReadVtable<GetCount>(sessionEnumerator, 3)(sessionEnumerator, out count));

            for (var sessionIndex = 0; sessionIndex < count; sessionIndex++)
            {
                IntPtr control;

                if (ReadVtable<GetSession>(sessionEnumerator, 4)(sessionEnumerator, sessionIndex, out control) != 0 || control == IntPtr.Zero)
                {
                    continue;
                }

                var extendedControl = QueryInterface(control, AudioSessionControlInterfaceId);

                if (extendedControl == IntPtr.Zero)
                {
                    Marshal.Release(control);
                    continue;
                }

                int processId;
                var invalidProcess = ReadVtable<GetProcessId>(extendedControl, 14)(extendedControl, out processId) != 0 || processId == 0;
                Marshal.Release(extendedControl);

                if (invalidProcess)
                {
                    Marshal.Release(control);
                    continue;
                }

                var volume = QueryInterface(control, SimpleAudioVolumeInterfaceId);
                Marshal.Release(control);

                if (volume == IntPtr.Zero)
                {
                    continue;
                }

                if (volumes.ContainsKey(processId))
                {
                    Marshal.Release(volume);
                }
                else
                {
                    volumes[processId] = volume;
                }
            }

            Marshal.Release(sessionEnumerator);
            Marshal.Release(manager);
            Marshal.Release(device);
            Marshal.Release(enumerator);
            Marshal.Release(unknown);

            return volumes;
        }

        public static float GetVolume(IntPtr volume)
        {
            float level;
            Marshal.ThrowExceptionForHR(ReadVtable<GetMasterVolume>(volume, 4)(volume, out level));

            return level;
        }

        public static void SetVolume(IntPtr volume, float level)
        {
            var context = Guid.Empty;
            Marshal.ThrowExceptionForHR(ReadVtable<SetMasterVolume>(volume, 3)(volume, level, ref context));
        }
    }
}
