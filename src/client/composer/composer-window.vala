/* Copyright 2016 Software Freedom Conservancy Inc.
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution.
 */

/**
 * A ComposerWindow is a ComposerContainer that is used to compose mails in a separate window
 * (i.e. detached) of its own.
 */
public class ComposerWindow : Gtk.ApplicationWindow, ComposerContainer {

    public Gtk.ApplicationWindow top_window {
        get { return this; }
    }

    internal ComposerWidget composer { get; set; }

    protected Gee.MultiMap<string, string>? old_accelerators { get; set; }

    private bool closing = false;

    public ComposerWindow(ComposerWidget composer) {
        Object(type: Gtk.WindowType.TOPLEVEL);
        this.composer = composer;

        // Make sure it gets added to the GtkApplication, to get the window-specific
        // composer actions to work properly.
        GearyApplication.instance.add_window(this);

        // XXX Bug 764622
        set_property("name", "GearyComposerWindow");

        add(this.composer);
        focus_in_event.connect(on_focus_in);
        focus_out_event.connect(on_focus_out);

        if (composer.config.desktop_environment == Configuration.DesktopEnvironment.UNITY) {
            composer.embed_header();
            composer.bind_property("window-title", this, "title", BindingFlags.SYNC_CREATE);
        } else {
            this.composer.header.show_close_button = true;
            this.composer.free_header();
            set_titlebar(this.composer.header);
            composer.bind_property("window-title", this.composer.header, "title",
                                   BindingFlags.SYNC_CREATE);
        }

        show();
        set_position(Gtk.WindowPosition.CENTER);
    }

    public override void show() {
        Gdk.Screen? screen = get_screen();
        if (screen != null) {
            int screen_width = screen.get_width();
            int screen_height = screen.get_height();
            int[] size = GearyApplication.instance.config.composer_window_size;

            //check if stored values are reasonable
            if (size[0] >= 0 && size[0] <= screen_width &&
                size[1] >= 0 && size[1] <= screen_height)
                set_default_size(size[0], size[1]);
            else
                set_default_size(680, 600);
        }

        base.show();
    }

    private void save_window_geometry () {
        Gdk.Screen? screen = get_screen();
        if (screen != null && !this.is_maximized) {
            int screen_width = screen.get_width();
            int screen_height = screen.get_height();

            int width = 0;
            int height = 0;

            get_size(out width, out height);

            // Only store if the values are reasonable-looking.
            if (width > 0 && width <= screen_width &&
                height > 0 && height <= screen_height)
                GearyApplication.instance.config.composer_window_size = { width, height };
        }
    }

    // Fired on window resize. Save window size for the next start.
    public override void size_allocate(Gtk.Allocation allocation) {
        base.size_allocate(allocation);

        this.save_window_geometry();
    }

    public void close_container() {
        on_focus_out();
        this.composer.editor.focus_in_event.disconnect(on_focus_in);
        this.composer.editor.focus_out_event.disconnect(on_focus_out);

        this.closing = true;
        destroy();
    }

    public override bool delete_event(Gdk.EventAny event) {
        return !(this.closing ||
            ((ComposerWidget) get_child()).should_close() == ComposerWidget.CloseStatus.DO_CLOSE);
    }

    public void vanish() {
        hide();
    }

    public void remove_composer() {
        warning("Detached composer received remove");
    }
}

