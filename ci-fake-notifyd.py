# A notification server that speaks the freedesktop protocol like GNOME and KDE do: it advertises "actions",
# records what it was sent, then "clicks" the default action two seconds later.
import dbus, dbus.service, dbus.mainloop.glib, json
from gi.repository import GLib
dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
class N(dbus.service.Object):
    @dbus.service.method("org.freedesktop.Notifications", out_signature="as")
    def GetCapabilities(self): return ["actions", "body"]
    @dbus.service.method("org.freedesktop.Notifications", out_signature="ssss")
    def GetServerInformation(self): return ("fake", "ktd-ci", "1", "1.2")
    @dbus.service.method("org.freedesktop.Notifications", in_signature="susssasa{sv}i", out_signature="u")
    def Notify(self, app, rid, icon, summary, body, actions, hints, timeout):
        json.dump({"app": str(app), "summary": str(summary), "body": str(body), "actions": [str(a) for a in actions]}, open("received.json", "w"))
        GLib.timeout_add(2000, self.click)
        return 7
    def click(self):
        self.ActionInvoked(7, "default"); self.NotificationClosed(7, 2); return False
    @dbus.service.signal("org.freedesktop.Notifications", signature="us")
    def ActionInvoked(self, i, a): pass
    @dbus.service.signal("org.freedesktop.Notifications", signature="uu")
    def NotificationClosed(self, i, r): pass
bus = dbus.SessionBus(); name = dbus.service.BusName("org.freedesktop.Notifications", bus)
N(bus, "/org/freedesktop/Notifications"); GLib.MainLoop().run()
