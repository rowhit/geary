/* Copyright 2016 Software Freedom Conservancy Inc.
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution.
 */

/**
 * The Geary email engine initial entry points.
 *
 * Engine represents and contains interfaces into the rest of the email library.  It's a singleton
 * class (see {@link instance}) with various signals for event notification.  Engine is initialized
 * by calling {@link open_async} and closed with {@link close_async}.
 *
 * Engine can list existing {@link Account} objects and create/delete them.  It can also validate
 * changes to Accounts prior to saving those changes.
 */
public class Geary.Engine : BaseObject {

    private const string ID_PREFIX = "account_";
    private const string ID_FORMAT = "account_%02u";

    [Flags]
    public enum ValidationOption {
        NONE = 0,
        CHECK_CONNECTIONS,
        UPDATING_EXISTING;
        
        public inline bool is_all_set(ValidationOption options) {
            return (options & this) == options;
        }
    }
    
    [Flags]
    public enum ValidationResult {
        OK = 0,
        INVALID_NICKNAME,
        EMAIL_EXISTS,
        IMAP_CONNECTION_FAILED,
        IMAP_CREDENTIALS_INVALID,
        SMTP_CONNECTION_FAILED,
        SMTP_CREDENTIALS_INVALID;
        
        public inline bool is_all_set(ValidationResult result) {
            return (result & this) == result;
        }
    }
    
    private static Engine? _instance = null;
    public static Engine instance {
        get {
            return (_instance != null) ? _instance : (_instance = new Engine());
        }
    }

    public File? user_data_dir { get; private set; default = null; }
    public File? user_config_dir { get; private set; default = null; }
    public File? resource_dir { get; private set; default = null; }
    public Geary.CredentialsMediator? authentication_mediator { get; private set; default = null; }
    
    private bool is_initialized = false;
    private bool is_open = false;
    private Gee.HashMap<string, AccountInformation>? accounts = null;
    private Gee.HashMap<string, Account>? account_instances = null;

    /**
     * Fired when the engine is opened and all the existing accounts are loaded.
     */
    public signal void opened();

    /**
     * Fired when the engine is closed.
     */
    public signal void closed();

    /**
     * Fired when an account becomes available in the engine.  Opening the
     * engine makes all existing accounts available; newly created accounts are
     * also made available as soon as they're stored.
     */
    public signal void account_available(AccountInformation account);

    /**
     * Fired when an account becomes unavailable in the engine.  Closing the
     * engine makes all accounts unavailable; deleting an account also makes it
     * unavailable.
     */
    public signal void account_unavailable(AccountInformation account);

    /**
     * Fired when a new account is created.
     */
    public signal void account_added(AccountInformation account);

    /**
     * Fired when an account is deleted.
     */
    public signal void account_removed(AccountInformation account);
    
    /**
     * Fired when an {@link Endpoint} associated with the {@link AccountInformation} reports
     * TLS certificate warnings during connection.
     *
     * This may be fired during normal operation or while validating the AccountInformation, in
     * which case there is no {@link Account} associated with it.
     */
    public signal void untrusted_host(Geary.AccountInformation account_information,
        Endpoint endpoint, Endpoint.SecurityType security, TlsConnection cx, Service service);

    // Public so it can be tested
    public Engine() {
    }

    private void check_opened() throws EngineError {
        if (!is_open)
            throw new EngineError.OPEN_REQUIRED("Geary.Engine instance not open");
    }
    
    // This can't be called from within the ctor, as initialization code may want to access the
    // Engine instance to make their own calls and, in particular, subscribe to signals.
    //
    // TODO: It would make sense to have a terminate_library() call, but it technically should not
    // be called until the application is exiting, not merely if the Engine is closed, as termination
    // means shutting down resources for good
    private void initialize_library() {
        if (is_initialized)
            return;
        
        is_initialized = true;
        
        AccountInformation.init();
        Logging.init();
        RFC822.init();
        Imap.init();
        HTML.init();
    }
    
    /**
     * Initializes the engine, and makes all existing accounts available.  The
     * given authentication mediator will be used to retrieve all passwords
     * when necessary.
     */
    public async void open_async(File user_config_dir, File user_data_dir, File resource_dir,
        Geary.CredentialsMediator? authentication_mediator, Cancellable? cancellable = null) throws Error {
        // initialize *before* opening the Engine ... all initialize code should assume the Engine
        // is closed
        initialize_library();
        
        if (is_open)
            throw new EngineError.ALREADY_OPEN("Geary.Engine instance already open");
        
        this.user_config_dir = user_config_dir;
        this.user_data_dir = user_data_dir;
        this.resource_dir = resource_dir;
        this.authentication_mediator = authentication_mediator;

        accounts = new Gee.HashMap<string, AccountInformation>();
        account_instances = new Gee.HashMap<string, Account>();

        is_open = true;

        yield add_existing_accounts_async(cancellable);
        
        opened();
   }

    private async void add_existing_accounts_async(Cancellable? cancellable = null) throws Error {
        try {
            user_data_dir.make_directory_with_parents(cancellable);
        } catch (IOError e) {
            if (!(e is IOError.EXISTS))
                throw e;
        }

        FileEnumerator enumerator
            = yield user_config_dir.enumerate_children_async("standard::*",
                FileQueryInfoFlags.NONE, Priority.DEFAULT, cancellable);
        
        Gee.List<AccountInformation> account_list = new Gee.ArrayList<AccountInformation>();
        
        for (;;) {
            List<FileInfo> info_list;
            try {
                info_list = yield enumerator.next_files_async(1, Priority.DEFAULT, cancellable);
            } catch (Error e) {
                debug("Error enumerating existing accounts: %s", e.message);
                break;
            }

            if (info_list.length() == 0)
                break;

            FileInfo info = info_list.nth_data(0);
            if (info.get_file_type() == FileType.DIRECTORY) {
                try {
                    string id = info.get_name();
                    account_list.add(
                        new AccountInformation.from_file(
                            id,
                            user_config_dir.get_child(id),
                            user_data_dir.get_child(id)
                        )
                    );
                } catch (Error err) {
                    warning("Ignoring empty/bad config in %s: %s",
                            info.get_name(), err.message);
                }
            }
        }

        foreach(AccountInformation info in account_list)
            add_account(info);
     }

    /**
     * Uninitializes the engine, and makes all accounts unavailable.
     */
    public async void close_async(Cancellable? cancellable = null) throws Error {
        if (!is_open)
            return;
        
        Gee.Collection<AccountInformation> unavailable_accounts = accounts.values;
        accounts.clear();
        
        foreach(AccountInformation account in unavailable_accounts)
            account_unavailable(account);
        
        user_data_dir = null;
        resource_dir = null;
        authentication_mediator = null;
        accounts = null;
        account_instances = null;
        
        is_open = false;
        closed();
    }

    /**
     * Returns a current account given its id.
     *
     * Throws an error if the engine has not been opened or if the
     * requested account does not exist.
     */
    public AccountInformation get_account(string id) throws Error {
        check_opened();

        AccountInformation? info = accounts.get(id);
        if (info == null) {
            throw new EngineError.NOT_FOUND("No such account: %s", id);
        }
        return info;
    }

    /**
     * Returns the current accounts list as a map keyed by account id.
     *
     * Throws an error if the engine has not been opened.
     */
    public Gee.Map<string, AccountInformation> get_accounts() throws Error {
        check_opened();

        return accounts.read_only_view;
    }

    /**
     * Returns a new account, not yet stored on disk.
     *
     * Throws an error if the engine has not been opened or if an
     * invalid account id is generated.
     */
    public AccountInformation create_orphan_account() throws Error {
        check_opened();

        // We might want to allow the client to specify the id, but
        // just generate one here for now: Use a common prefix and a
        // numeric suffix, starting at 1. To generate the next id,
        // find the last account and increment its suffix.

        string? last_account = this.accounts.keys.fold<string?>((next, last) => {
                string? result = last;
                if (next.has_prefix(ID_PREFIX)) {
                    result = (last == null || strcmp(last, next) < 0) ? next : last;
                }
                return result;
            },
            null);
        uint next_id = 1;
        if (last_account != null) {
            next_id = int.parse(last_account.substring(ID_PREFIX.length)) + 1;
        }
        string id = ID_FORMAT.printf(next_id);

        if (this.accounts.has_key(id))
            throw new EngineError.ALREADY_EXISTS("Account %s already exists", id);

        return new AccountInformation(
            id, user_config_dir.get_child(id), user_data_dir.get_child(id)
        );
    }

    /**
     * Returns whether the account information "validates."  If validate_connection is true,
     * we check if we can connect to the endpoints and authenticate using the supplied credentials.
     */
    public async ValidationResult validate_account_information_async(AccountInformation account,
        ValidationOption options, Cancellable? cancellable = null) throws Error {
        check_opened();
        
        ValidationResult error_code = ValidationResult.OK;
        
        // Make sure the account nickname and email is not in use.
        foreach (AccountInformation a in get_accounts().values) {
            // Don't need to check a's alternate_emails since they
            // can't be set at account creation time
            bool has_email = account.has_email_address(a.primary_mailbox);

            if (!has_email && Geary.String.stri_equal(account.nickname, a.nickname))
                error_code |= ValidationResult.INVALID_NICKNAME;

            // if creating a new Account, don't allow an existing email address
            if (!options.is_all_set(ValidationOption.UPDATING_EXISTING) && has_email)
                error_code |= ValidationResult.EMAIL_EXISTS;
        }
        
        // If we don't need to validate the connection, exit out here.
        if (!options.is_all_set(ValidationOption.CHECK_CONNECTIONS))
            return error_code;
        
        account.untrusted_host.connect(on_untrusted_host);
        
        // validate IMAP, which requires logging in and establishing an AUTHORIZED cx state
        Geary.Imap.ClientSession? imap_session = new Imap.ClientSession(account.get_imap_endpoint());
        try {
            yield imap_session.connect_async(cancellable);
        } catch (Error err) {
            debug("Error connecting to IMAP server: %s", err.message);
            error_code |= ValidationResult.IMAP_CONNECTION_FAILED;
        }
        
        if (!error_code.is_all_set(ValidationResult.IMAP_CONNECTION_FAILED)) {
            try {
                yield imap_session.initiate_session_async(account.imap_credentials, cancellable);
                
                // Connected and initiated, still need to be sure connection authorized
                Imap.MailboxSpecifier current_mailbox;
                if (imap_session.get_protocol_state(out current_mailbox) != Imap.ClientSession.ProtocolState.AUTHORIZED)
                    error_code |= ValidationResult.IMAP_CREDENTIALS_INVALID;
            } catch (Error err) {
                debug("Error validating IMAP account info: %s", err.message);
                if (err is ImapError.UNAUTHENTICATED)
                    error_code |= ValidationResult.IMAP_CREDENTIALS_INVALID;
                else
                    error_code |= ValidationResult.IMAP_CONNECTION_FAILED;
            }
        }
        
        try {
            yield imap_session.disconnect_async(cancellable);
        } catch (Error err) {
            // ignored
        } finally {
            imap_session = null;
        }
        
        // SMTP is simpler, merely see if login works and done (throws an SmtpError if not)
        Geary.Smtp.ClientSession? smtp_session = new Geary.Smtp.ClientSession(account.get_smtp_endpoint());
        try {
            yield smtp_session.login_async(account.smtp_credentials, cancellable);
        } catch (Error err) {
            debug("Error validating SMTP account info: %s", err.message);
            if (err is SmtpError.AUTHENTICATION_FAILED)
                error_code |= ValidationResult.SMTP_CREDENTIALS_INVALID;
            else
                error_code |= ValidationResult.SMTP_CONNECTION_FAILED;
        }
        
        try {
            yield smtp_session.logout_async(true, cancellable);
        } catch (Error err) {
            // ignored
        } finally {
            smtp_session = null;
        }
        
        account.untrusted_host.disconnect(on_untrusted_host);
        
        return error_code;
    }
    
    /**
     * Creates a Geary.Account from a Geary.AccountInformation (which is what
     * other methods in this interface deal in).
     */
    public Geary.Account get_account_instance(AccountInformation account_information)
        throws Error {
        check_opened();

        if (account_instances.has_key(account_information.id))
            return account_instances.get(account_information.id);

        ImapDB.Account local_account = new ImapDB.Account(account_information);
        Imap.Account remote_account = new Imap.Account(account_information);

        Geary.Account account;
        switch (account_information.service_provider) {
            case ServiceProvider.GMAIL:
                account = new ImapEngine.GmailAccount("Gmail:%s".printf(account_information.id),
                    account_information, remote_account, local_account);
            break;

            case ServiceProvider.YAHOO:
                account = new ImapEngine.YahooAccount("Yahoo:%s".printf(account_information.id),
                    account_information, remote_account, local_account);
            break;

            case ServiceProvider.OUTLOOK:
                account = new ImapEngine.OutlookAccount("Outlook:%s".printf(account_information.id),
                    account_information, remote_account, local_account);
            break;

            case ServiceProvider.OTHER:
                account = new ImapEngine.OtherAccount("Other:%s".printf(account_information.id),
                    account_information, remote_account, local_account);
            break;

            default:
                assert_not_reached();
        }

        account_instances.set(account_information.id, account);
        return account;
    }

    /**
     * Adds the account to be tracked by the engine.  Should only be called from
     * AccountInformation.store_async() and this class.
     */
    public void add_account(AccountInformation account, bool created = false) throws Error {
        check_opened();

        bool already_added = accounts.has_key(account.id);

        accounts.set(account.id, account);

        if (!already_added) {
            account.untrusted_host.connect(on_untrusted_host);
            
            if (created)
                account_added(account);
            
            account_available(account);
        }
    }

    /**
     * Deletes the account from disk.
     */
    public async void remove_account_async(AccountInformation account,
                                           Cancellable? cancellable = null) throws Error {
        check_opened();
        
        // Ensure account is closed.
        if (account_instances.has_key(account.id) && account_instances.get(account.id).is_open()) {
            throw new EngineError.CLOSE_REQUIRED("Account %s must be closed before removal",
                account.id);
        }

        if (accounts.unset(account.id)) {
            account.untrusted_host.disconnect(on_untrusted_host);

            // Removal *MUST* be done in the following order:
            // 1. Send the account-unavailable signal.
            account_unavailable(account);
            
            // 2. Delete the corresponding files.
            yield account.remove_async(cancellable);
            
            // 3. Send the account-removed signal.
            account_removed(account);
            
            // 4. Remove the account data from the engine.
            account_instances.unset(account.id);
        }
    }

    private void on_untrusted_host(AccountInformation account_information, Endpoint endpoint,
        Endpoint.SecurityType security, TlsConnection cx, Service service) {
        untrusted_host(account_information, endpoint, security, cx, service);
    }
}

