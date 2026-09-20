// ab-monitor.exe - read MSI Afterburner shared memory (MAHM) and log it to CSV.
// Layout (probed on this machine, MAHM version 0x00020000):
//   header: +0x08 headerSize(=32)  +0x0C entryCount  +0x10 entrySize(=1324)
//   entry : +0 name(260) +260 units(260) +520 locName(260) +780 locUnits(260)
//           +1040 format(260) +1300 value(float)
// Usage: ab-monitor.exe --list
//        ab-monitor.exe <out.csv> <seconds> [interval_ms]
// NOTE: keep this file pure ASCII (compiled by csc.exe).

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.MemoryMappedFiles;
using System.Text;
using System.Threading;

internal static class AbMonitor
{
    private const string MapName = "MAHMSharedMemory";
    private const int NameLen = 260;
    private const int ValueOffset = 1300;

    private static int Main(string[] args)
    {
        bool listOnly = false;
        List<string> pos = new List<string>();
        foreach (string a in args)
        {
            if (a == "--list") listOnly = true;
            else pos.Add(a);
        }
        if (listOnly) return List();
        if (pos.Count < 2)
        {
            Console.Error.WriteLine("usage: ab-monitor.exe --list");
            Console.Error.WriteLine("       ab-monitor.exe <out.csv> <seconds> [interval_ms]");
            return 2;
        }
        string outPath = pos[0];
        int seconds = int.Parse(pos[1], CultureInfo.InvariantCulture);
        int intervalMs = pos.Count > 2 ? int.Parse(pos[2], CultureInfo.InvariantCulture) : 2000;
        return Sample(outPath, seconds, intervalMs);
    }

    private static string ReadStr(byte[] buf, int off, int max)
    {
        int end = off;
        int limit = off + max;
        while (end < limit && buf[end] != 0) end++;
        return Encoding.ASCII.GetString(buf, off, end - off);
    }

    private static int FindName(string[] names, string want)
    {
        for (int i = 0; i < names.Length; i++) if (names[i] == want) return i;
        return -1;
    }

    private static float At(float[] v, int idx)
    {
        return (idx >= 0 && idx < v.Length) ? v[idx] : 0f;
    }

    private static int List()
    {
        try
        {
            using (MemoryMappedFile mmf = MemoryMappedFile.OpenExisting(MapName, MemoryMappedFileRights.Read))
            using (MemoryMappedViewAccessor acc = mmf.CreateViewAccessor(0, 0, MemoryMappedFileAccess.Read))
            {
                int cap = (int)acc.Capacity;
                byte[] buf = new byte[cap];
                acc.ReadArray(0, buf, 0, cap);
                int headerSize = (int)BitConverter.ToUInt32(buf, 0x08);
                int entryCount = (int)BitConverter.ToUInt32(buf, 0x0C);
                int entrySize = (int)BitConverter.ToUInt32(buf, 0x10);
                Console.WriteLine("headerSize=" + headerSize + " entryCount=" + entryCount + " entrySize=" + entrySize);
                for (int e = 0; e < entryCount; e++)
                {
                    int off = headerSize + e * entrySize;
                    if (off + ValueOffset + 4 > cap) break;
                    string name = ReadStr(buf, off, NameLen);
                    string units = ReadStr(buf, off + NameLen, NameLen);
                    float val = BitConverter.ToSingle(buf, off + ValueOffset);
                    Console.WriteLine(string.Format(CultureInfo.InvariantCulture, "{0,3}  {1,-26} {2,-8} {3,12:0.###}", e, name, units, val));
                }
            }
            return 0;
        }
        catch (Exception ex) { Console.Error.WriteLine("ERROR: " + ex.GetType().Name + ": " + ex.Message); return 3; }
    }

    private static int Sample(string outPath, int seconds, int intervalMs)
    {
        try
        {
            using (MemoryMappedFile mmf = MemoryMappedFile.OpenExisting(MapName, MemoryMappedFileRights.Read))
            using (MemoryMappedViewAccessor acc = mmf.CreateViewAccessor(0, 0, MemoryMappedFileAccess.Read))
            using (StreamWriter w = new StreamWriter(outPath, false, new UTF8Encoding(false)))
            {
                int cap = (int)acc.Capacity;
                byte[] buf = new byte[cap];
                acc.ReadArray(0, buf, 0, cap);
                int headerSize = (int)BitConverter.ToUInt32(buf, 0x08);
                int entryCount = (int)BitConverter.ToUInt32(buf, 0x0C);
                int entrySize = (int)BitConverter.ToUInt32(buf, 0x10);

                string[] names = new string[entryCount];
                StringBuilder sb = new StringBuilder("time");
                for (int e = 0; e < entryCount; e++)
                {
                    int off = headerSize + e * entrySize;
                    if (off + ValueOffset + 4 > cap) break;
                    names[e] = ReadStr(buf, off, NameLen);
                    sb.Append(',').Append('\"').Append(names[e].Replace("\"", "\"\"")).Append('\"');
                }
                w.WriteLine(sb.ToString());
                w.Flush();

                int iGpuT = FindName(names, "GPU temperature");
                int iGpuP = FindName(names, "Power");
                int iGpuU = FindName(names, "GPU usage");
                int iCpuT = FindName(names, "CPU temperature");
                int iCpuP = FindName(names, "CPU power");
                int iCpuU = FindName(names, "CPU usage");
                int iLimP = FindName(names, "Power limit");
                int iLimT = FindName(names, "Temp limit");
                int iLimV = FindName(names, "Voltage limit");

                Console.WriteLine("logging -> " + outPath);
                Console.WriteLine("duration=" + seconds + "s  interval=" + intervalMs + "ms");
                Console.WriteLine("-------------------------------------------------------------------");

                float[] vals = new float[entryCount];
                DateTime t0 = DateTime.Now;
                int n = 0;
                float maxCpuT = 0f, maxGpuT = 0f, maxTotal = 0f;

                while ((DateTime.Now - t0).TotalSeconds < seconds)
                {
                    acc.ReadArray(0, buf, 0, cap);
                    sb.Length = 0;
                    sb.Append(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture));
                    for (int e = 0; e < entryCount; e++)
                    {
                        int off = headerSize + e * entrySize;
                        if (off + ValueOffset + 4 > cap) break;
                        float v = BitConverter.ToSingle(buf, off + ValueOffset);
                        vals[e] = v;
                        sb.Append(',').Append(v.ToString("0.###", CultureInfo.InvariantCulture));
                    }
                    w.WriteLine(sb.ToString());
                    w.Flush();
                    n++;

                    float gT = At(vals, iGpuT), gP = At(vals, iGpuP), gU = At(vals, iGpuU);
                    float cT = At(vals, iCpuT), cP = At(vals, iCpuP), cU = At(vals, iCpuU);
                    float total = gP + cP;
                    if (cT > maxCpuT) maxCpuT = cT;
                    if (gT > maxGpuT) maxGpuT = gT;
                    if (total > maxTotal) maxTotal = total;

                    double elapsed = (DateTime.Now - t0).TotalSeconds;
                    Console.WriteLine(string.Format(CultureInfo.InvariantCulture,
                        "[{0,4:0}s] GPU {1,3:0}C {2,5:0.#}W {3,3:0}% | CPU {4,3:0}C {5,5:0.#}W {6,3:0}% | total {7,5:0.#}W | lim Pwr={8:0} Thm={9:0} Vlt={10:0}  ({11:0}s left)",
                        elapsed, gT, gP, gU, cT, cP, cU, total, At(vals, iLimP), At(vals, iLimT), At(vals, iLimV), seconds - elapsed));

                    Thread.Sleep(intervalMs);
                }

                Console.WriteLine("-------------------------------------------------------------------");
                Console.WriteLine(string.Format(CultureInfo.InvariantCulture,
                    "DONE samples={0}   peak: GPU {1:0}C / CPU {2:0}C / total {3:0.#}W", n, maxGpuT, maxCpuT, maxTotal));
            }
            return 0;
        }
        catch (Exception ex) { Console.Error.WriteLine("ERROR: " + ex.GetType().Name + ": " + ex.Message); return 3; }
    }
}