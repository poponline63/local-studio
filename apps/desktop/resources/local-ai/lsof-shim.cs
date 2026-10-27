// lsof shim for the Local Studio controller on Windows (it calls `lsof -nP -iTCP -sTCP:LISTEN -F pn`).
// Local-only allowlist: reports ONLY Ollama (11434), Local Studio registry engine ports (18100-18299) and the ports of the
// extra servers listed in the private per-user config (%USERPROFILE%\.local-studio-t3\local-ai-extra.json, or
// LOCALAI_EXTRA_CONFIG), listening on loopback/any address, so the gateway never discovers other /v1 proxies on this PC.
using System; using System.Diagnostics; using System.IO; using System.Text.RegularExpressions;
class P {
  static System.Collections.Generic.HashSet<int> ExtraPorts() {
    var set = new System.Collections.Generic.HashSet<int>();
    try {
      string cfg = Environment.GetEnvironmentVariable("LOCALAI_EXTRA_CONFIG");
      if (String.IsNullOrEmpty(cfg)) cfg = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local-studio-t3", "local-ai-extra.json");
      if (File.Exists(cfg)) foreach (Match m in Regex.Matches(File.ReadAllText(cfg), "\"port\"\\s*:\\s*(\\d+)")) set.Add(int.Parse(m.Groups[1].Value));
    } catch { }
    return set;
  }
  static int Main() {
    var extra = ExtraPorts();
    var psi = new ProcessStartInfo("netstat", "-ano -p TCP") { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true };
    var p = Process.Start(psi); string o = p.StandardOutput.ReadToEnd(); p.WaitForExit();
    var seen = new System.Collections.Generic.HashSet<int>();
    foreach (Match m in Regex.Matches(o, @"^\s*TCP\s+(\S+):(\d+)\s+\S+\s+LISTENING\s+(\d+)", RegexOptions.Multiline)) {
      int port = int.Parse(m.Groups[2].Value); string host = m.Groups[1].Value;
      if (!(port == 11434 || extra.Contains(port) || (port >= 18100 && port <= 18299))) continue;
      if (!(host == "127.0.0.1" || host == "0.0.0.0")) continue;
      if (!seen.Add(port)) continue;
      Console.Write("p" + m.Groups[3].Value + "\nn127.0.0.1:" + port + "\n");
    }
    return 0;
  }
}
