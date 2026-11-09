// Minimale Attrappen fuer System.Windows.Forms/System.Drawing, damit der ABLAUF der Eltern-Zentrale
// (Funktionen, Variablen, StrictMode, Handler) auf Linux durchlaufen werden kann. Prueft NICHT, ob die
// echten WinForms-Eigenschaften stimmen - das geht nur auf Windows.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Dynamic;

namespace StubDrawing {
    public struct Point { public int X, Y; public Point(int x, int y) { X = x; Y = y; } }
    public struct Size { public int Width, Height; public Size(int w, int h) { Width = w; Height = h; } }
    [Flags] public enum FontStyle { Regular = 0, Bold = 1 }
    public class Font { public Font(string n, float s) { } public Font(string n, float s, FontStyle st) { } }
    public static class Color {
        public static object DimGray = "DimGray", DarkGreen = "DarkGreen", Firebrick = "Firebrick", DarkOrange = "DarkOrange", Black = "Black";
    }
}
namespace System.Windows.Forms {
    public enum DialogResult { None, OK, Cancel, Yes, No }
    public enum MessageBoxButtons { OK, YesNo }
    public enum MessageBoxIcon { None, Information, Warning, Error, Question }
    public enum DateTimePickerFormat { Long, Short, Time, Custom }
    public class WorkArea { public int Right = 1920, Bottom = 1040; }
    public class ScreenInfo { public WorkArea WorkingArea = new WorkArea(); }
    public static class Screen { public static ScreenInfo PrimaryScreen = new ScreenInfo(); }
    public class ListBox : Control { public ItemList Items = new ItemList(); }
    public static class Clipboard { public static void SetText(string t) { Stub.Clip = t; } }
    public static class Application { public static void EnableVisualStyles() { } }
    public static class Stub {
        public static List<Control> All = new List<Control>();
        public static List<string> Messages = new List<string>();
        public static string PinText = "";
        public static Action<Form> OnMainForm;
        public static Action<Form> OnRelayDialog;
        public static string Clip = "";
    }
    public static class MessageBox {
        public static DialogResult Show(string text, string title, MessageBoxButtons b, MessageBoxIcon i) {
            Stub.Messages.Add(title + " | " + text);
            return b == MessageBoxButtons.YesNo ? DialogResult.Yes : DialogResult.OK;
        }
    }
    public class ItemList : ArrayList { public override int Add(object x) { return base.Add(U.Un(x) is string ? U.Un(x) : x); } }
    public static class U { public static object Un(object o) { if (o != null && o.GetType().Name == "PSObject") return o.GetType().GetProperty("BaseObject").GetValue(o); return o; } }
    public class ControlCollection : ArrayList {
        public void AddRange(object[] a) { foreach (var x in a) Add(x); }
        public new void Add(object x) { base.Add(U.Un(x)); }
    }
    public class Control : DynamicObject {
        public Dictionary<string, object> P = new Dictionary<string, object>();
        public Dictionary<string, List<object>> Handlers = new Dictionary<string, List<object>>();
        public ControlCollection Controls = new ControlCollection();
        public Control() { Stub.All.Add(this); }
        public void Dispose() { }
        public void Close() { }
        public void Start() { }
        public void Stop() { }
        public override bool TryGetMember(GetMemberBinder b, out object r) {
            if (b.Name == "Controls") { r = Controls; return true; }
            P.TryGetValue(b.Name, out r); return true;
        }
        public override bool TrySetMember(SetMemberBinder b, object v) { P[b.Name] = v; return true; }
        public override bool TryInvokeMember(InvokeMemberBinder b, object[] a, out object r) {
            r = null;
            if (b.Name.StartsWith("Add_")) {
                var n = b.Name.Substring(4);
                if (!Handlers.ContainsKey(n)) Handlers[n] = new List<object>();
                Handlers[n].Add(a[0]);
            }
            return true;
        }
    }
    public class ComboBox : Control {
        public ItemList Items = new ItemList();
        int idx = -1;
        public override bool TryGetMember(GetMemberBinder b, out object r) {
            if (b.Name == "Items") { r = Items; return true; }
            if (b.Name == "SelectedIndex") { r = idx; return true; }
            if (b.Name == "SelectedItem") { r = (idx >= 0 && idx < Items.Count) ? Items[idx] : null; return true; }
            return base.TryGetMember(b, out r);
        }
        public override bool TrySetMember(SetMemberBinder b, object v) {
            if (b.Name == "SelectedIndex") { idx = Convert.ToInt32(v); Fire("SelectedIndexChanged"); return true; }
            return base.TrySetMember(b, v);
        }
        void Fire(string n) { List<object> l; if (Handlers.TryGetValue(n, out l)) foreach (dynamic h in l) h.Invoke(this, null); }
    }
    public class Label : Control { } public class Button : Control { } public class GroupBox : Control { }
    public class TextBox : Control { } public class NumericUpDown : Control { } public class CheckBox : Control { }
    public class DateTimePicker : Control { } public class Timer : Control { }
    public class Form : Control {
        public DialogResult ShowDialog() {
            object tag; if (P.TryGetValue("Tag", out tag) && tag != null && tag.ToString() == "relay") { if (Stub.OnRelayDialog != null) Stub.OnRelayDialog(this); return DialogResult.Cancel; }
            var main = true; foreach (var c0 in Controls) { if (c0 is TextBox) main = false; }  // PIN-Dialog hat direkt eine TextBox, Hauptfenster nicht
            if (!main) {
                foreach (var c in Controls) { var t = c as TextBox; if (t != null) t.P["Text"] = Stub.PinText; }
                return DialogResult.OK;
            }
            if (Stub.OnMainForm != null) Stub.OnMainForm(this);
            return DialogResult.OK;
        }
    }
}
