"""Reviewed presentation members; internal exceptions are exact, never name-wide."""

from publication_lifecycle import ATTRIBUTE_EXCEPTIONS as LIFECYCLE_EXCEPTIONS, ATTRIBUTE_CONTEXTS as LIFECYCLE_CONTEXTS

APPROVED_ATTRIBUTES = frozenset("""
Argument BLANK Changed Context DictWriter Exit FIRST_COMPLETED InputEvent Option Pressed
RowHighlighted RowSelected StringIO Submitted TabActivated Typer WRITE_FEATURES
action_add action_add_developer action_advanced action_apply action_assistant_configure
action_assistant_history action_assistant_pins action_boost action_budget_history action_bulk
action_compare action_copy_request action_decide action_disposition action_edit action_exact_detail
action_export action_filter action_gateway_probe action_group_lookup action_help action_load_view
action_lookup action_membership action_mode action_month action_notifications action_open_ledger
action_overview_rank action_pin_chart action_priced_usage action_profile action_publish_as_admin
action_read_notification action_refresh action_refresh_membership action_refresh_usage action_remove
action_remove_view action_report_generate action_request_budget action_request_time_usage
action_revoke_boost action_save_view action_scope_filters action_show_boosts action_sign_out
action_tab action_usd_edit action_usd_reconcile activate_profile active add add_class add_column
add_columns add_row add_typer advanced_view allowed_tabs apim_name app append apply applying
approvals_view as_completed ascii ask ask_conversation ask_current ask_history ask_reply
ask_reply_guard astimezone available_themes backend begin_load boost border_title breadcrumbs
budget_change budget_parent budget_warning_threshold busy button cached_guard call_after_refresh
call_later call_next call_at call_soon call_on_close callback cancel capabilities capitalize
casefold catalog_change change_reason change_widgets chargeback check_action children clear
clear_publication_notifications clear_query_context close code command commands compare_period
compare_trends compose_feature config configure_assistant control copy_to_clipboard create_task
current_guard cursor cursor_row cursor_stack data data_table debounce decide_request detail
detail_widgets details dimension discard dismiss display disposition done dumps editable
enabled engine environ exit extend feature_button feature_caps feature_cursor
feature_cursor_stack feature_select fields filters first first_run focus focused form_widgets
fromisoformat fromkeys fullmatch gather get get_line_filters get_running_loop get_tab getvalue
governance has_feature heading height hide_tab highlight id identity identity_independent_reads
identity_listeners identity_revision immediate_writes initialize_features insert interval
invoked_subcommand is_mounted is_running isoformat items join key keys kind load_developers
load_feature_tab load_groups load_overview load_tab load_text loads lookup lower mark_notification
mark_toured match matcher maximum_boost_days maybe_tour membership_url meta mode_change
monotonic month mount move_cursor mutation mutation_metadata name native_modes
native_user_budget_records navigate_selected now obj on_event open_cached_change
open_current_row open_detail open_lookup_result open_selected open_url operation
optional_dashboard_read page_feature page_people pane parameters parse_args pending_selection
edit update_cell update_cell_at partial
people_cursor people_cursor_stack people_filter people_offset people_query person_budget_period
person_detail pin_chart pin_read_cycle pop pop_screen populate_rows preferences present
prevent preview preview_only preview_plan public publish_developers publish_groups
publish_notification publish_tab push_cached_form push_screen query query_one ranking_dimension
read read_cycle read_guard read_only records redactor refresh refresh_bindings refresh_features
register_theme remove remove_class remove_view removeprefix removing render render_tab replace
request_before request_budget request_cursor request_filters request_page require require_feature
requires_reason reset_paging reset_people_page restore_view result results results_guard
returncode revoke_boost row rows rows_widgets run run_worker safe_message_guard save_view saved
scope_filters scope_kind screen_stack search search_text select selected set_class set_comparison
set_focus set_interval set_options set_timer setdefault show_tab signature size sleep split
splitlines startswith status stop strftime strip style subscription team tenant_id text theme
tier_change time title to_thread total_seconds toured tzinfo update update_access update_brand
update_data update_filter_chips update_key_hints upper url usage_basis usd_budget_change
usd_price_book_change usd_reconcile usd_status utc value values verifying_identity views wait
wait_for_apply which width workspace_resource_id writeheader writerow
action_chargeback apply_label auto_export before commit_preview configuration connection_kind
connection_label export local_write membership_unavailable_text open_add_form path prefill_unit
prefill_user profile_path publication_scroll_home resource_group revision scope update_action_buttons
usd_unavailable_text validate
action_clear_filter action_next_page action_previous_page action_quit action_remove_developer
commit_action commit_change open_remove_form quit_message refresh_saving run_mutation saving
""".split())

EXCLUDED_ATTRIBUTES = frozenset({
    "console", "error_console", "file", "stdout", "stderr", "driver", "_driver",
    "write", "writelines", "notify",
})

# Filled by the reviewed AST inventory, then checked against the exact source.
ATTRIBUTE_EXCEPTIONS = {
    ('cli.py', 'EverywhereGroup.parse_args', 'super().parse_args(ctx, prefix + rest)'):
        'Forwards the fixed superclass operation on self in this reviewed wrapper/adapter; no supplied class or instance selects a base implementation.',
    ('dashboard.py', 'Dashboard.update_data', 'self._anomalies'):
        'Calls the existing dashboard value-formatting helper inside its reviewed source-guarded rendering context.',
    ('dashboard.py', 'Dashboard.update_data', 'self._rankings'):
        'Calls the existing dashboard value-formatting helper inside its reviewed source-guarded rendering context.',
    ('dashboard.py', 'Dashboard.update_data', 'self._risks'):
        'Calls the existing dashboard value-formatting helper inside its reviewed source-guarded rendering context.',
    ('dashboard.py', 'Dashboard.update_data', 'self._trends'):
        'Calls the existing dashboard value-formatting helper inside its reviewed source-guarded rendering context.',
    ('dashboard.py', 'DashboardPanel.__init__', "super().__init__('Loading live facts...', id=panel_id, classes='dashboard-panel', markup=False)"):
        'Forwards the fixed superclass operation on self in this reviewed wrapper/adapter; no supplied class or instance selects a base implementation.',
    ('dashboard.py', 'DashboardPanel.on_key', 'self.app._error_text'):
        'Formats the existing safe domain error through redaction; this is not access to a raw error console or traceback renderer.',
    ('dashboard_drill.py', 'DashboardRows.__init__', 'super().__init__()'):
        'Forwards the fixed superclass operation on self in this reviewed wrapper/adapter; no supplied class or instance selects a base implementation.',
    ('dashboard_drill.py', 'DashboardRows.action_detail', 'self.app._error_text'):
        'Formats the existing safe domain error through redaction; this is not access to a raw error console or traceback renderer.',
    ('dashboard_drill.py', 'DashboardRows.compose', 'self.app._error_text'):
        'Formats the existing safe domain error through redaction; this is not access to a raw error console or traceback renderer.',
    ('dashboard_drill.py', 'DashboardRows.on_mount', 'self.app._error_text'):
        'Formats the existing safe domain error through redaction; this is not access to a raw error console or traceback renderer.',
    ('dashboard_drill.py', 'DashboardRows.open_row', 'self.app._error_text'):
        'Formats the existing safe domain error through redaction; this is not access to a raw error console or traceback renderer.',
    ('dashboard_drill.py', 'DashboardRows.open_selected', 'self.app._error_text'):
        'Formats the existing safe domain error through redaction; this is not access to a raw error console or traceback renderer.',
    ('developer_screens.py', 'DeveloperPicker.__init__', 'super().__init__()'):
        'Forwards the fixed superclass operation on self in this reviewed wrapper/adapter; no supplied class or instance selects a base implementation.',
    ('feature_engine.py', 'FeatureEngine._feature_change', 'self.backend.write'):
        'Delegates the existing authorized feature operation to its backend API; this is not a stream write or a presentation output capability.',
    ('feature_engine.py', 'FeatureEngine.ask', 'self.backend.write'):
        'Delegates the existing authorized feature operation to its backend API; this is not a stream write or a presentation output capability.',
    ('feature_engine.py', 'FeatureEngine.boost', 'self._feature_change'):
        'Calls the existing validated feature-engine helper in this exact context; it returns values rather than output capabilities.',
    ('feature_engine.py', 'FeatureEngine.boost', 'self._future_expiry'):
        'Calls the existing validated feature-engine helper in this exact context; it returns values rather than output capabilities.',
    ('feature_engine.py', 'FeatureEngine.boost', 'self._reason'):
        'Calls the existing validated feature-engine helper in this exact context; it returns values rather than output capabilities.',
    ('feature_engine.py', 'FeatureEngine.capabilities', 'self._capabilities'):
        'Reads verified identity or cycle-pinned capability state under the existing feature-engine validation and locking context.',
    ('feature_engine.py', 'FeatureEngine.capabilities', 'self._capabilities_guard'):
        'Reads verified identity or cycle-pinned capability state under the existing feature-engine validation and locking context.',
    ('feature_engine.py', 'FeatureEngine.capabilities', 'self._capabilities_lock'):
        'Reads verified identity or cycle-pinned capability state under the existing feature-engine validation and locking context.',
    ('feature_engine.py', 'FeatureEngine.capabilities', 'self._identity'):
        'Reads verified identity or cycle-pinned capability state under the existing feature-engine validation and locking context.',
    ('feature_engine.py', 'FeatureEngine.configure_assistant', 'self.backend.write'):
        'Delegates the existing authorized feature operation to its backend API; this is not a stream write or a presentation output capability.',
    ('feature_engine.py', 'FeatureEngine.decide_request', 'self._feature_change'):
        'Calls the existing validated feature-engine helper in this exact context; it returns values rather than output capabilities.',
    ('feature_engine.py', 'FeatureEngine.decide_request', 'self._reason'):
        'Calls the existing validated feature-engine helper in this exact context; it returns values rather than output capabilities.',
    ('feature_engine.py', 'FeatureEngine.disposition', 'self._feature_change'):
        'Calls the existing validated feature-engine helper in this exact context; it returns values rather than output capabilities.',
    ('feature_engine.py', 'FeatureEngine.disposition', 'self._reason'):
        'Calls the existing validated feature-engine helper in this exact context; it returns values rather than output capabilities.',
    ('feature_engine.py', 'FeatureEngine.mark_notification', 'self._feature_change'):
        'Calls the existing validated feature-engine helper in this exact context; it returns values rather than output capabilities.',
    ('feature_engine.py', 'FeatureEngine.mode_change', 'self.backend.write'):
        'Delegates the existing authorized feature operation to its backend API; this is not a stream write or a presentation output capability.',
    ('feature_engine.py', 'FeatureEngine.pin_chart', 'self._feature_change'):
        'Calls the existing validated feature-engine helper in this exact context; it returns values rather than output capabilities.',
    ('feature_engine.py', 'FeatureEngine.request_budget', 'self._feature_change'):
        'Calls the existing validated feature-engine helper in this exact context; it returns values rather than output capabilities.',
    ('feature_engine.py', 'FeatureEngine.request_budget', 'self._future_expiry'):
        'Calls the existing validated feature-engine helper in this exact context; it returns values rather than output capabilities.',
    ('feature_engine.py', 'FeatureEngine.request_budget', 'self._reason'):
        'Calls the existing validated feature-engine helper in this exact context; it returns values rather than output capabilities.',
    ('feature_engine.py', 'FeatureEngine.revoke_boost', 'self._feature_change'):
        'Calls the existing validated feature-engine helper in this exact context; it returns values rather than output capabilities.',
    ('feature_screens.py', 'ActionForm.__init__', 'super().__init__()'):
        'Forwards the fixed superclass operation on self in this reviewed wrapper/adapter; no supplied class or instance selects a base implementation.',
    ('feature_screens.py', 'ActionForm.compose', 'self.app._error_text'):
        'Formats the existing safe domain error through redaction; this is not access to a raw error console or traceback renderer.',
    ('group_screens.py', 'GroupPicker.__init__', 'super().__init__()'):
        'Forwards the fixed superclass operation on self in this reviewed wrapper/adapter; no supplied class or instance selects a base implementation.',
    ('principal_ui.py', 'PrincipalUI._bind_engine', 'self._principal_verified'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('principal_ui.py', 'PrincipalUI._clear_principal_state', 'hasattr(screen, name)'):
        'Checks only the fixed cache-field tuple before clearing non-callable fields and closing obsolete dialogs.',
    ('principal_ui.py', 'PrincipalUI._clear_principal_state', 'self._data_guards'):
        'Reads the data-to-origin cache used by the existing guarded publication path; the cache is not a raw output handle.',
    ('principal_ui.py', 'PrincipalUI._clear_principal_state', 'self._show_read_error'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('principal_ui.py', 'PrincipalUI._clear_principal_state', 'self._waiting'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('principal_ui.py', 'PrincipalUI._principal_verified', 'self._principal_revision'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('principal_ui.py', 'PrincipalUI._principal_verified', 'self._synchronize_principal'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('principal_ui.py', 'PrincipalUI._reject_publication', 'self._clear_principal_state'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('principal_ui.py', 'PrincipalUI._reject_publication', 'self._clearing_principal'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('principal_ui.py', 'PrincipalUI._reject_publication', 'self._show_read_error'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('principal_ui.py', 'PrincipalUI._reject_publication', 'self._synchronize_principal'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('principal_ui.py', 'PrincipalUI._reject_publication', 'self.engine._identity'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('principal_ui.py', 'PrincipalUI._synchronize_principal', 'self._clear_principal_state'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('principal_ui.py', 'PrincipalUI._synchronize_principal', 'self._clearing_principal'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('principal_ui.py', 'PrincipalUI._synchronize_principal', 'self._pending_principal'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('principal_ui.py', 'PrincipalUI._synchronize_principal', 'self._principal_revision'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('principal_ui.py', 'PrincipalUI._synchronize_principal', 'self.engine._identity'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('principal_ui.py', 'PrincipalUI.cached_guard', 'self._data_guards'):
        'Reads the data-to-origin cache used by the existing guarded publication path; the cache is not a raw output handle.',
    ('principal_ui.py', 'PrincipalUI.current_guard', 'self._reject_publication'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('principal_ui.py', 'PrincipalUI.on_event', 'self._synchronize_principal'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('principal_ui.py', 'PrincipalUI.on_event', 'super().on_event(event)'):
        'Forwards the fixed superclass operation on self in this reviewed wrapper/adapter; no supplied class or instance selects a base implementation.',
    ('principal_ui.py', 'PrincipalUI.open_cached_change', 'self._error_text'):
        'Formats the existing safe domain error through redaction; this is not access to a raw error console or traceback renderer.',
    ('progressive.py', 'ProgressiveRefresh._current_refresh', 'self._refresh_serial'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('progressive.py', 'ProgressiveRefresh._show_read_error', 'self._error_text'):
        'Formats the existing safe domain error through redaction; this is not access to a raw error console or traceback renderer.',
    ('progressive.py', 'ProgressiveRefresh._show_wait', 'self._principal_notice'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('progressive.py', 'ProgressiveRefresh._show_wait', 'self._refresh_started'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('progressive.py', 'ProgressiveRefresh._show_wait', 'self._waiting'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('progressive.py', 'ProgressiveRefresh._tracked_read', 'self._current_refresh'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('progressive.py', 'ProgressiveRefresh._tracked_read', 'self._show_wait'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('progressive.py', 'ProgressiveRefresh._tracked_read', 'self._waiting'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('progressive.py', 'ProgressiveRefresh.action_refresh', 'self._current_refresh'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('progressive.py', 'ProgressiveRefresh.action_refresh', 'self._error_text'):
        'Formats the existing safe domain error through redaction; this is not access to a raw error console or traceback renderer.',
    ('progressive.py', 'ProgressiveRefresh.action_refresh', 'self._metadata_or_data_error'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('progressive.py', 'ProgressiveRefresh.action_refresh', 'self._refresh_serial'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('progressive.py', 'ProgressiveRefresh.action_refresh', 'self._show_identity'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('progressive.py', 'ProgressiveRefresh.action_refresh', 'self._show_read_error'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('progressive.py', 'ProgressiveRefresh.action_refresh', 'self._show_wait'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('progressive.py', 'ProgressiveRefresh.action_refresh', 'self._tracked_read'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('progressive.py', 'ProgressiveRefresh.action_refresh', 'self._waiting'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('progressive.py', 'ProgressiveRefresh.load_overview', 'self._current_refresh'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('progressive.py', 'ProgressiveRefresh.load_overview', 'self._refresh_serial'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('progressive.py', 'ProgressiveRefresh.load_overview', 'self._show_wait'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('progressive.py', 'ProgressiveRefresh.load_overview.fetch', 'self._error_text'):
        'Formats the existing safe domain error through redaction; this is not access to a raw error console or traceback renderer.',
    ('progressive.py', 'ProgressiveRefresh.load_overview.fetch', 'self._tracked_read'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('progressive.py', 'ProgressiveRefresh.publish_tab', 'self._data_guards'):
        'Reads the data-to-origin cache used by the existing guarded publication path; the cache is not a raw output handle.',
    ('progressive.py', 'ProgressiveRefresh.publish_tab', 'self._show_read_error'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('publication_output.py', 'prompt_number', 'typer.prompt'):
        'The CLI prompt is an explicit protected IO operation, not a terminal-UI-thread read.',
    ('publication_output.py', 'read_text', 'Path(path).read_text'):
        'Reads the operator-selected input file and returns text, never a file handle, to presentation.',
    ('publication_output.py', 'terminal_output', 'sys.stdout'):
        'The boundary queries terminal attachment only; the stream is never returned to presentation.',
    ('publication_output.py', 'terminal_output', 'sys.stdout.isatty'):
        'The boundary returns only a terminal-presence boolean, never the raw stdout stream.',
    ('publication_output.py', 'write_export', 'stream.write'):
        'The final file write occurs inside the synchronous publication sink and its held originating guard.',
    ('publication_output.py', 'write_export', 'target.open'):
        'The guarded export opens the chosen file only after origin validation and never returns its handle.',
    ('publication_output.py', 'write_export', 'target.parent'):
        'Parent-directory creation is contained inside the guarded export; no Path object escapes to presentation.',
    ('publication_output.py', 'write_export', 'target.parent.mkdir'):
        'The guarded export validates its origin before creating any output directory.',
    ('publication_output.py', 'write_renderable', 'target.print'):
        'The final Rich write occurs only inside the protected renderable sink.',
    ('publication_output.py', 'write_text', 'typer.echo'):
        'The final terminal write occurs only inside the protected text sink.',
    ('publication_widgets.py', 'ModalScreen.__init__', 'super().__init__(*args, **kwargs)'):
        'Forwards the fixed superclass operation on self in this reviewed wrapper/adapter; no supplied class or instance selects a base implementation.',
    ('publication_widgets.py', 'PublicationApp._deliver_notifications', 'guards.enter_context'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationApp._deliver_notifications', 'notification.origin'):
        'Reads the retained content or notification origin before publication; no replacement caller origin is inferred.',
    ('publication_widgets.py', 'PublicationApp._deliver_notifications', 'rack._toast_id'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationApp._deliver_notifications', 'rack.scroll_end'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationApp._deliver_notifications', 'self._notifications'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationApp._deliver_notifications', 'self.screen'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationApp._dispatch_action', 'inspect.isawaitable'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationApp._dispatch_action', 'namespace._framework_callback'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationApp._dispatch_action', 'namespace.input_origin'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationApp._dispatch_action', 'super()._dispatch_action(namespace, action_name, params)'):
        'Forwards the fixed superclass operation on self in this reviewed wrapper/adapter; no supplied class or instance selects a base implementation.',
    ('publication_widgets.py', 'PublicationApp._handle_exception', 'self._publication_rejected'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationApp._handle_exception', 'super()._handle_exception(error)'):
        'Forwards the fixed superclass operation on self in this reviewed wrapper/adapter; no supplied class or instance selects a base implementation.',
    ('publication_widgets.py', 'PublicationApp._on_notify', 'event.notification'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationApp._on_notify', 'notification.origin'):
        'Reads the retained content or notification origin before publication; no replacement caller origin is inferred.',
    ('publication_widgets.py', 'PublicationApp._on_notify', 'self._notifications'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationApp._on_notify', 'self._refresh_notifications'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationApp._process_messages', 'loop.get_exception_handler'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationApp._process_messages', 'loop.set_exception_handler'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationApp._process_messages', 'super()._process_messages(*args, **kwargs)'):
        'Forwards the fixed superclass operation on self in this reviewed wrapper/adapter; no supplied class or instance selects a base implementation.',
    ('publication_widgets.py', 'PublicationApp._process_messages.handle', 'loop.default_exception_handler'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationApp._process_messages.handle', 'self._handle_exception'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationApp._publication_rejected', 'self._reject_publication'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationApp._refresh_notifications', 'self._deliver_notifications'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationApp._refresh_notifications', 'self._disable_notifications'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationApp._register', 'guards.enter_context'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationApp._register', 'super()._register(parent, *widgets, **kwargs)'):
        'Forwards the fixed superclass operation on self in this reviewed wrapper/adapter; no supplied class or instance selects a base implementation.',
    ('publication_widgets.py', 'PublicationApp._register', 'widget._pending_children'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationApp._register', 'widget._publication_origin'):
        'Reads the retained content or notification origin before publication; no replacement caller origin is inferred.',
    ('publication_widgets.py', 'PublicationApp.clear_publication_notifications', 'self._notifications'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationApp.clear_publication_notifications', 'self._refresh_notifications'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationApp.copy_to_clipboard', 'super().copy_to_clipboard(text)'):
        'Forwards the fixed superclass operation on self in this reviewed wrapper/adapter; no supplied class or instance selects a base implementation.',
    ('publication_widgets.py', 'PublicationApp.open_url', 'super().open_url(url, new_tab=new_tab)'):
        'Forwards the fixed superclass operation on self in this reviewed wrapper/adapter; no supplied class or instance selects a base implementation.',
    ('publication_widgets.py', 'PublicationApp.publish_notification', 'self.NOTIFICATION_TIMEOUT'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationApp.publish_notification', 'self.post_message'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationDispatch._dispatch_message', 'self.app._handle_exception'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationDispatch._dispatch_message', 'super()._dispatch_message(message)'):
        'Forwards the fixed superclass operation on self in this reviewed wrapper/adapter; no supplied class or instance selects a base implementation.',
    ('publication_widgets.py', 'PublicationWidget.__init__', 'super().__init__(*args, **kwargs)'):
        'Forwards the fixed superclass operation on self in this reviewed wrapper/adapter; no supplied class or instance selects a base implementation.',
    ('publication_widgets.py', 'PublicationWidget.__setattr__', 'self._set_presentation'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationWidget._framework_callback', 'inspect.iscoroutinefunction'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationWidget._framework_callback.run', 'self._publication_rejected'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationWidget._get_dispatch_methods', 'self._framework_callback'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationWidget._get_dispatch_methods', 'self._publication_origin'):
        'Reads the retained content or notification origin before publication; no replacement caller origin is inferred.',
    ('publication_widgets.py', 'PublicationWidget._get_dispatch_methods', 'self.input_origin'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationWidget._get_dispatch_methods', 'super()._get_dispatch_methods(method_name, message)'):
        'Forwards the fixed superclass operation on self in this reviewed wrapper/adapter; no supplied class or instance selects a base implementation.',
    ('publication_widgets.py', 'PublicationWidget._publication_rejected', 'self.app._reject_publication'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationWidget.input_origin', 'self._publication_origin'):
        'Reads the retained content or notification origin before publication; no replacement caller origin is inferred.',
    ('publication_widgets.py', 'PublicationWidget.input_origin', 'self._publication_rejected'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', 'PublicationWidget.input_origin', 'source.content_origin'):
        'Reads the retained content or notification origin before publication; no replacement caller origin is inferred.',
    ('publication_widgets.py', '_PublicationToast._discard', 'self.app._handle_exception'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', '_PublicationToast.render', 'self._discard'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', '_PublicationToast.render', 'self._publication_origin'):
        'Reads the retained content or notification origin before publication; no replacement caller origin is inferred.',
    ('publication_widgets.py', '_PublicationToast.render', 'super().render()'):
        'Forwards the fixed superclass operation on self in this reviewed wrapper/adapter; no supplied class or instance selects a base implementation.',
    ('publication_widgets.py', '_PublicationToast.render_lines', 'Strip.blank'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', '_PublicationToast.render_lines', 'self._discard'):
        'Uses the app-owned framework state or fixed lifecycle operation within the reviewed publication boundary; no raw capability is exported.',
    ('publication_widgets.py', '_PublicationToast.render_lines', 'self._publication_origin'):
        'Reads the retained content or notification origin before publication; no replacement caller origin is inferred.',
    ('publication_widgets.py', '_PublicationToast.render_lines', 'super().render_lines(crop)'):
        'Forwards the fixed superclass operation on self in this reviewed wrapper/adapter; no supplied class or instance selects a base implementation.',
    ('screens.py', 'ChangeScreen.__init__', 'super().__init__()'):
        'Forwards the fixed superclass operation on self in this reviewed wrapper/adapter; no supplied class or instance selects a base implementation.',
    ('screens.py', 'ChangeScreen.compose', 'self.app._error_text'):
        'Formats the existing safe domain error through redaction; this is not access to a raw error console or traceback renderer.',
    ('screens.py', 'DetailScreen.__init__', 'super().__init__()'):
        'Forwards the fixed superclass operation on self in this reviewed wrapper/adapter; no supplied class or instance selects a base implementation.',
    ('screens.py', 'DetailScreen.compose', 'self.app._error_text'):
        'Formats the existing safe domain error through redaction; this is not access to a raw error console or traceback renderer.',
    ('tui.py', 'FinOpsApp.__init__', 'self._bind_engine'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('tui.py', 'FinOpsApp.__init__', 'super().__init__()'):
        'Forwards the fixed superclass operation on self in this reviewed wrapper/adapter; no supplied class or instance selects a base implementation.',
    ('tui.py', 'FinOpsApp._render_tab', 'self._data_guards'):
        'Reads the data-to-origin cache used by the existing guarded publication path; the cache is not a raw output handle.',
    ('tui.py', 'FinOpsApp.exact_on_focus', 'self._publish_highlight'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('tui.py', 'FinOpsApp.exact_on_focus', 'self._show_read_error'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('tui.py', 'FinOpsApp.exact_on_focus', 'self._synchronize_principal'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('tui.py', 'FinOpsApp.get_line_filters', 'super().get_line_filters()'):
        'Forwards the fixed superclass operation on self in this reviewed wrapper/adapter; no supplied class or instance selects a base implementation.',
    ('tui.py', 'FinOpsApp.open_detail', 'self._data_guards'):
        'Reads the data-to-origin cache used by the existing guarded publication path; the cache is not a raw output handle.',
    ('tui.py', 'FinOpsApp.open_detail', 'self._open_detail'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('tui.py', 'FinOpsApp.render_tab', 'self._data_guards'):
        'Reads the data-to-origin cache used by the existing guarded publication path; the cache is not a raw output handle.',
    ('tui.py', 'FinOpsApp.render_tab', 'self._render_tab'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('tui.py', 'FinOpsApp.render_tab', 'self._show_read_error'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('tui.py', 'FinOpsApp.selected', 'self._synchronize_principal'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('tui.py', 'FinOpsApp.switched', 'self._principal_notice'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('tui.py', 'FinOpsApp.update_access', 'self._data_guards'):
        'Reads the data-to-origin cache used by the existing guarded publication path; the cache is not a raw output handle.',
    ('tui.py', 'FinOpsApp.update_brand', 'self._synchronize_principal'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('ui_features.py', 'FeatureUI._show_read_detail', 'self._error_text'):
        'Formats the existing safe domain error through redaction; this is not access to a raw error console or traceback renderer.',
    ('ui_features.py', 'FeatureUI._show_read_detail', 'self._publish_read'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('ui_features.py', 'FeatureUI.action_assistant_configure.load', 'self._publish_read'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('ui_features.py', 'FeatureUI.action_assistant_history', 'self._show_read_detail'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('ui_features.py', 'FeatureUI.action_assistant_pins', 'self._show_read_detail'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('ui_features.py', 'FeatureUI.action_budget_history', 'self._show_read_detail'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('ui_features.py', 'FeatureUI.action_copy_request', 'self._error_text'):
        'Formats the existing safe domain error through redaction; this is not access to a raw error console or traceback renderer.',
    ('ui_features.py', 'FeatureUI.action_membership.load', 'self._publish_read'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('ui_features.py', 'FeatureUI.action_notifications', 'self._show_read_detail'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('ui_features.py', 'FeatureUI.action_pin_chart', 'self._error_text'):
        'Formats the existing safe domain error through redaction; this is not access to a raw error console or traceback renderer.',
    ('ui_features.py', 'FeatureUI.action_show_boosts', 'self._show_read_detail'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('ui_features.py', 'FeatureUI.activate_profile', 'self._bind_engine'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('ui_features.py', 'FeatureUI.activate_profile', 'self._data_guards'):
        'Reads the data-to-origin cache used by the existing guarded publication path; the cache is not a raw output handle.',
    ('ui_features.py', 'FeatureUI.activate_profile', 'self._error_text'):
        'Formats the existing safe domain error through redaction; this is not access to a raw error console or traceback renderer.',
    ('ui_features.py', 'FeatureUI.ask_current', 'self._publish_read'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('ui_features.py', 'FeatureUI.ask_current', 'self._synchronize_principal'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('ui_features.py', 'FeatureUI.push_cached_form', 'self._error_text'):
        'Formats the existing safe domain error through redaction; this is not access to a raw error console or traceback renderer.',
    ('ui_features.py', 'FeatureUI.refresh_features', 'self._apply_features'):
        'Uses the existing principal or refresh state/helper in this exact reviewed lifecycle context, without exposing framework IO.',
    ('publication_widgets.py', '_PayloadFreeRepresentation.__repr__', 'type(self).__name__'):
        'Reports only the framework type name, never a payload or callback argument.',
    ('publication_widgets.py', '_seal_message', 'original.__name__'):
        'Preserves the message type name while replacing both diagnostic representations.',
    ('publication_widgets.py', '_seal_message', 'original.__module__'):
        'Preserves framework message identity for dispatch; it does not import or expose the module.',
    ('publication_widgets.py', '_seal_message', 'original.__qualname__'):
        'Preserves framework message identity while keeping its diagnostic payload opaque.',
    ('publication_widgets.py', '_seal_message', 'original.bubble'):
        'Copies the existing message routing flag without changing its delivery semantics.',
    ('publication_widgets.py', '_seal_message', 'original.verbose'):
        'Preserves the framework diagnostic level; payload removal does not disable logging.',
    ('publication_widgets.py', '_seal_message', 'original.no_dispatch'):
        'Preserves whether the original message dispatches; only its representations change.',
    ('publication_widgets.py', '_seal_message', 'protected.handler_name = original.handler_name'):
        'Copies the existing handler name to the private cached adapter so dispatch remains unchanged.',
    ('publication_widgets.py', '_seal_message', 'message.__class__ = protected'):
        'Seals this queued Message before framework logging; only its payload-free adapter is assigned.',
    ('publication_widgets.py', '_retained_framework_watcher', 'callback.func'):
        'Recognizes only the exact Textual await_watcher function, not arbitrary deferred callbacks.',
    ('publication_widgets.py', '_retained_framework_watcher', 'callback.args'):
        'Checks the watcher owner before retaining its origin; this does not display callback arguments.',
    ('publication_widgets.py', '_retained_framework_watcher', 'owner._publication_origin'):
        'Retains the protected widget source for the exact framework watcher callback.',
    ('publication_widgets.py', '_RetainedWatcher.__call__', 'self.origin'):
        'Re-enters the captured source at watcher execution rather than using the later caller.',
    ('publication_widgets.py', '_RetainedWatcher.__call__', 'self.owner._publication_rejected'):
        'Reports only the safe domain refusal and keeps the framework message loop alive.',
    ('publication_widgets.py', '_RetainedWatcher.close', 'self.callback.args'):
        'Finds the coroutine in the already-validated await_watcher binding for deterministic cleanup.',
    ('publication_widgets.py', '_RetainedWatcher.close', 'inspect.iscoroutine(pending)'):
        'Classifies only the retained watcher awaitable so an unused coroutine can be closed.',
    ('publication_widgets.py', '_RetainedWatcher.close', 'pending.cr_running'):
        'Never closes a running coroutine while disposing of a refused or abandoned watcher.',
    ('publication_widgets.py', 'PublicationDispatch.post_message', 'super().post_message(message)'):
        'Forwards the same message only after its payload-free representations have been installed.',
    ('publication_widgets.py', 'PublicationWidget._get_dispatch_methods', "getattr(type(self), '_publication_native_type', None)"):
        'Recognizes an already-approved native adapter for the fixed framework lifecycle handlers.',
    ('publication_widgets.py', 'PublicationWidget._get_dispatch_methods', 'cls.__module__'):
        'Limits retained-origin lifecycle dispatch to the reviewed framework implementation.',
    ('publication_widgets.py', 'PublicationWidget.get_child_by_type', "getattr(actual, '_publication_native_type', None)"):
        'Restores exact native child-type lookup without returning an unprotected receiver.',
    ('publication_widgets.py', '_protect_native_widget.initialize', 'original.__init__(owner, *args, **kwargs)'):
        'Calls the exact approved native constructor only inside the publication sink.',
    ('publication_widgets.py', '_protect_native_widget.set_presentation', 'original.__setattr__(owner, name, value)'):
        'Writes through the native descriptor only after the receiver publication sink validates the source.',
    ('publication_widgets.py', '_protect_native_widget.render', 'owner._publication_origin'):
        'Validates the retained native content source before fresh rendering.',
    ('publication_widgets.py', '_protect_native_widget.render', 'owner._cached_publication_rejected'):
        'Reports stale native paint without cancelling a newer source read; refused output stays blank.',
    ('publication_widgets.py', '_protect_native_widget.render_lines', 'owner._publication_origin'):
        'Validates the retained native source before returning even cached render strips.',
    ('publication_widgets.py', '_protect_native_widget.render_lines', 'original.render_lines'):
        'Reads native cached strips only within the retained source guard.',
    ('publication_widgets.py', '_protect_native_widget.render_lines', 'owner._cached_publication_rejected'):
        'Reports stale cached paint without clearing newer facts or returning any cached payload.',
    ('publication_widgets.py', '_protect_native_widget.render_lines', 'Strip.blank'):
        'Returns empty fixed-width strips after an explicit domain refusal, never cached content.',
    ('publication_widgets.py', '_protect_native_widget.post_message', 'original.post_message'):
        'Forwards a native receiver message only after payload-free sealing.',
    ('publication_widgets.py', '_protect_native_widget.dispatch', 'original._dispatch_message'):
        'Seals the message before entering the original native dispatch and logging path.',
    ('publication_widgets.py', '_protect_native_widget.dispatch', 'owner.app._handle_exception'):
        'Routes only recognized publication refusals to the existing safe application handler.',
    ('publication_widgets.py', '_protect_native_widget.dispatch_methods', 'original._get_dispatch_methods'):
        'Enumerates native handlers so only the fixed reviewed lifecycle and input handlers gain an origin.',
    ('publication_widgets.py', '_protect_native_widget.dispatch_methods', 'operation.__name__'):
        'Matches the fixed reviewed framework handler vocabulary, not arbitrary application callbacks.',
    ('publication_widgets.py', '_protect_native_widget.dispatch_methods', 'cls.__module__'):
        'Restricts native lifecycle authority to framework methods of an explicitly approved receiver.',
    ('publication_widgets.py', '_protect_native_widget.dispatch_methods', 'owner.input_origin'):
        'Combines the retained content source and current input authority for real framework input events.',
    ('publication_widgets.py', '_protect_native_widget.dispatch_methods', 'owner._publication_origin'):
        'Keeps composition and mount callbacks attached to their original widget source.',
    ('publication_widgets.py', '_protect_native_widget.dispatch_methods', 'owner._framework_callback'):
        'Wraps the exact selected native handler in retained-origin deferred execution.',
    ('publication_widgets.py', '_protect_native_widget', 'PublicationWidget.__setattr__(owner, name, value)'):
        'Forwards to the protected receiver setter in the native-first adapter; it never exposes the raw setter.',
    ('publication_widgets.py', '_protect_native_widget', 'PublicationWidget.get_child_by_type'):
        'Installs exact protected-child lookup while preserving native framework type expectations.',
    ('publication_widgets.py', '_protect_native_widget', 'getattr(original, name, None)'):
        'Looks up only the fixed native write-method set on an exact approved framework type for wrapping.',
    ('publication_widgets.py', '_protect_native_widget', 'inspect.iscoroutinefunction(operation)'):
        'Keeps the synchronous sink wrapper off asynchronous bodies; unsupported content types are refused.',
    ('publication_widgets.py', '_protect_native_widget', 'original.__name__'):
        'Names the private cached native adapter without opening any new import or member capability.',
    ('publication_widgets.py', '_protect_native_widget', "object.__setattr__(widget, '_publication_origin', origin)"):
        'Retains the composing source before the approved native receiver enters the DOM.',
    ('publication_widgets.py', '_protect_native_widget', "object.__setattr__(widget, '__class__', protected)"):
        'Adapts only the exact approved native type before registration; ordinary class replacement stays refused.',
    ('publication_widgets.py', 'PublicationApp.__init__', 'super().__init__(*args, **kwargs)'):
        'Forwards native application construction before freezing the fixed framework title metadata.',
    ('publication_widgets.py', 'PublicationApp.__setattr__', "getattr(self, '_publication_static_titles', False)"):
        'Checks only whether initial native title setup is complete before refusing later title writes.',
    ('publication_widgets.py', 'PublicationApp.__setattr__', 'super().__setattr__(name, value)'):
        'Forwards non-title state and initial static title setup; later title output is explicitly refused.',
    ('publication_widgets.py', 'PublicationApp._register', 'parent._publication_origin'):
        'Native descendants inherit the protected composing parent source, not a replacement caller identity.',
    ('publication_widgets.py', 'PublicationWidget._cached_publication_rejected', "getattr(self, '_publication_render_refused', False)"):
        'Emits one fixed refusal notice per expired render origin instead of repeatedly clearing current data.',
    ('publication_widgets.py', '_protect_native_widget.run_worker', 'work.func'):
        'Recognizes only the exact native command-search coroutine, never an arbitrary supplied worker.',
    ('publication_widgets.py', '_protect_native_widget.run_worker', 'CommandPalette._gather_commands.__wrapped__'):
        'Identifies the reviewed Textual search worker before retaining its source and removing diagnostic arguments.',
    ('publication_widgets.py', '_protect_native_widget.run_worker', 'work.args'):
        'Requires the exact native receiver as the search worker owner before granting deferred authority.',
    ('publication_widgets.py', '_protect_native_widget.run_worker', 'owner._publication_origin'):
        'Retains the native search source through awaits rather than authorizing later unrelated callbacks.',
    ('developer_screens.py', 'DeveloperPicker.open_add_form', 'self.app._data_guards'):
        'Stores the catalog together with its original read guard before the combined directory/catalog form is published.',
    ('developer_screens.py', 'DeveloperPicker.open_add_form', 'self.app._error_text'):
        'Formats a redacted domain refusal for the protected status or retained-origin notification, never raw diagnostics.',
    ('screens.py', 'ExportScreen.__init__', 'super().__init__()'):
        'Initializes only the protected empty modal shell; source-backed content is composed under its explicit guard.',
    ('ui_features.py', 'FeatureUI.activate_profile', 'self._clear_principal_state'):
        'Clears a partially adopted candidate after restoring the previous engine; no failed candidate data is republished.',
    ('publication_output.py', 'confirm_profile_replace', 'typer.confirm'):
        'The synchronous publication sink validates the source before the fixed replacement question is printed or read.',
    ('publication_output.py', 'profile_bytes', "(json.dumps(config.validate().public(), indent=2) + '\\n').encode"):
        'Encodes validated address-only configuration into immutable bytes, without opening or returning a file.',
    ('publication_output.py', 'read_profile', 'path.read_bytes'):
        'Reads an operator-selected local profile inside the output boundary and returns bytes, never its Path or handle.',
    ('publication_output.py', 'content_revision', 'hashlib.sha256(content).hexdigest()'):
        'Computes a value-only revision of the exact reviewed profile bytes for compare-before-write checks.',
    ('publication_output.py', 'ProfileChange.configuration', 'self.content'):
        'Decodes immutable reviewed address bytes into validated configuration without rediscovery or filesystem access.',
    ('publication_output.py', 'profile_lock', 'path.parent.mkdir(parents=True, exist_ok=True)'):
        'Creates the lock directory only during an explicit originating publication before transaction entry.',
    ('publication_output.py', 'profile_lock', 'path.with_name'):
        'Derives the persistent sibling lock path from the selected local profile; no path capability leaves the boundary.',
    ('publication_output.py', 'profile_lock', "path.with_name(f'.{path.name}.lock').open"):
        'Opens the persistent OS-lock handle only under the entering source guard, and closes it in finally.',
    ('publication_output.py', 'profile_lock', 'handle.seek'):
        'Positions the private Windows lock handle at the fixed first byte before nonblocking lock acquisition.',
    ('publication_output.py', 'profile_lock', 'handle.fileno'):
        'Passes only the private lock descriptor to the platform lock API; no descriptor is returned to presentation.',
    ('publication_output.py', 'profile_lock', 'msvcrt.locking'):
        'Acquires the existing nonblocking Windows profile writer lock under the entering publication guard.',
    ('publication_output.py', 'profile_lock', 'msvcrt.LK_NBLCK'):
        'Uses only the fixed nonblocking Windows lock mode, preserving immediate concurrent-writer refusal.',
    ('publication_output.py', 'profile_lock', 'fcntl.flock'):
        'Acquires the Unix profile writer lock under the entering guard; the private handle lifetime releases it.',
    ('publication_output.py', 'profile_lock', 'fcntl.LOCK_EX'):
        'Requests only an exclusive lock on the private profile-lock descriptor, not an arbitrary file operation.',
    ('publication_output.py', 'profile_lock', 'fcntl.LOCK_NB'):
        'Keeps Unix acquisition nonblocking so another writer is explicitly refused rather than hidden by a wait.',
    ('publication_output.py', 'profile_lock', 'error.errno'):
        'Classifies the OS lock error by number; unexpected errors propagate without printing sensitive diagnostics.',
    ('publication_output.py', 'profile_lock', 'errno.EACCES'):
        'Recognizes the existing access-denied lock contention code and returns the fixed actionable refusal.',
    ('publication_output.py', 'profile_lock', 'errno.EAGAIN'):
        'Recognizes the existing would-block lock contention code and returns the fixed actionable refusal.',
    ('publication_output.py', 'profile_lock', 'errno.EDEADLK'):
        'Recognizes the existing Windows lock contention code and returns the fixed actionable refusal.',
    ('publication_output.py', 'profile_conflict', 'Config.__dataclass_fields__'):
        'Reads only the declared address-field names to describe a conflict, never arbitrary profile bytes or reflection targets.',
    ('publication_output.py', 'backup_profile', 'path.read_bytes'):
        'Reads the exact previous profile bytes while the publication and OS writer locks protect backup creation.',
    ('publication_output.py', 'backup_profile', 'path.with_name'):
        'Builds a timestamped sibling backup name; exclusive creation refuses existing files and increments the suffix.',
    ('publication_output.py', 'backup_profile', 'path.stem'):
        'Uses the selected profile basename solely to form the non-overwriting timestamped backup filename.',
    ('publication_output.py', 'backup_profile', 'path.suffix'):
        'Preserves the selected profile extension in the sibling backup filename, without exposing a writer.',
    ('publication_output.py', 'backup_profile', 'backup.open'):
        'Creates a backup exclusively after the synchronous sink validates origin; the handle stays inside the boundary.',
    ('publication_output.py', 'backup_profile', 'stream.write'):
        'Writes only the exact previous profile bytes under the synchronous publication sink and OS writer lock.',
    ('publication_output.py', 'replace_profile', 'path.with_name'):
        'Derives a unique same-directory temporary file for atomic replacement of the selected local profile.',
    ('publication_output.py', 'replace_profile', 'uuid4().hex'):
        'Formats a fresh local temporary-name nonce, with no terminal, network or file capability in the returned value.',
    ('publication_output.py', 'replace_profile', 'temporary.open'):
        'Exclusively creates the private temporary file after origin validation, before its atomic rename.',
    ('publication_output.py', 'replace_profile', 'stream.write'):
        'Writes reviewed address bytes only inside the synchronous publication sink before atomic profile replacement.',
    ('publication_output.py', 'replace_profile', 'temporary.unlink'):
        'Removes only the private temporary file in finally after a guarded write attempt, never a wildcard or parent path.',
    ('publication_output.py', '_save_profile_locked', 'path.exists'):
        'Chooses whether a backup is needed inside the guarded transaction after checking the reviewed revision.',
    ('publication_output.py', 'profile_transaction', 'reviewed.content'):
        'Uses the immutable reviewed bytes for commit; final validation compares that same content before UI adoption.',
    ('publication_output.py', 'profile_transaction', 'path.unlink'):
        'Rollback removes only this transaction-created profile after its written revision still matches under the OS lock.',
    ('publication_output.py', 'profile_transaction', 'backup.read_bytes'):
        'Rollback restores the exact local backup bytes only after confirming no newer writer replaced the candidate.',
    ('publication_widgets.py', 'VerticalScroll.publication_scroll_home', 'self.input_origin'):
        'Validates both the protected recovery container content origin and the current app before exposing another cached viewport.',
    ('publication_widgets.py', 'VerticalScroll.publication_scroll_home', 'super().scroll_home(animate=False, immediate=True)'):
        'Forwards only this protected scroll receiver synchronously, without animation, deferred scroll work or supplied callbacks.',
}
ATTRIBUTE_EXCEPTIONS.update(LIFECYCLE_EXCEPTIONS)

ATTRIBUTE_CONTEXTS = {
    ('developer_screens.py', 'DeveloperPicker.open_add_form'): '5f095d01dbc48d70b45242154692faab781b14444b3977ad0693834a913a4faf',
    ('publication_output.py', 'ProfileChange.configuration'): '5f90fbf786853cee55bce5cf1e8e1cdc076b3a90741dc704e013aeed326eba50',
    ('publication_output.py', '_save_profile_locked'): '5b0d2aabacd92fd3eafc27ab722474e445bdd8894cf2b73f4954a00b18b2c3fd',
    ('publication_output.py', 'backup_profile'): 'd2ed1be45ec060b62a2e1098a487c380acf6bded01aea25fe3345c083c37907f',
    ('publication_output.py', 'confirm_profile_replace'): '95ecc41813ad7c4746282bd1bff8215dc0cb0ffeb1204a97fd9b43b0e966ffef',
    ('publication_output.py', 'content_revision'): 'ac111b9b7216c6659d8f2016d3a874493761df2b5533d49fd97aa95b1c398afa',
    ('publication_output.py', 'profile_bytes'): 'f7327adf997cef566979b2575b04292a47e679637f58586e5cfc24170253b475',
    ('publication_output.py', 'profile_conflict'): '1222d364c76fc13c039108d95ccf296bc1dc59018b846d8f723a1769ed446458',
    ('publication_output.py', 'profile_lock'): '867c87ef851ad95bef2afa073282ce17e3dc2c4245092ae4def7a6f71b1c1fc7',
    ('publication_output.py', 'profile_transaction'): 'b8574bbcc83b0740515e3f28979616333ed550c7a520000dee58aaf5d34c6e16',
    ('publication_output.py', 'read_profile'): '76c288c5e86915f8c5e7ff1390febbc9e21f7a387afd9f7318d2752dd269209a',
    ('publication_output.py', 'replace_profile'): '6396cdc80f654d0fe96df17c1eeef917ad883348dfe0564dd1000acab7f1d718',
    ('screens.py', 'ExportScreen.__init__'): '56e994644d8fbad53584de68d225bdfe6ba95e80973c13cd2556b6ac3d24e863',
    ('publication_widgets.py', 'VerticalScroll.publication_scroll_home'): 'b71b677c2cfd7b8e6a87595d79b0cd39fa29be34c11fc8a75bbefecd2f2f95d1',
    ('publication_widgets.py', 'PublicationWidget._cached_publication_rejected'): '24237ea443e6c2f109ab9fa1e40ac8d5707977be96fd34f50a33e012bf4be5fc',
    ('publication_widgets.py', '_protect_native_widget.run_worker'): '269748d99db8daf61176eb72ca37aa81be93d1d336ef2591c585c4ebb24f4b5d',
    ('publication_widgets.py', 'PublicationApp.__init__'): '9701aaa1c5d249d98401fd341b50fbb0133770e1fd1e73783b31c7f8f7bc0dda',
    ('publication_widgets.py', 'PublicationApp.__setattr__'): 'f5b2bfd2c557ef7e19f73c3bf82553137f1f45a62e94efc4710942671a4d2df1',
    ('publication_widgets.py', 'PublicationDispatch.post_message'): '2a5441ede1674c938ff5175d2be0ed4ec198202697f097b252ebdc300e77971b',
    ('publication_widgets.py', 'PublicationWidget.get_child_by_type'): 'd1e385a67bb390f5c7b96469cd3ea3ab15c2194e6f6eecb0eed6e91211dda85f',
    ('publication_widgets.py', '_PayloadFreeRepresentation.__repr__'): 'e6954331835e9a3a585c65e83a9690d25b91e96877c0bd9c1aa768e27a047958',
    ('publication_widgets.py', '_RetainedWatcher.__call__'): 'c8aff46b4df6f505e8fbdf387824c69ec90750b487aeac21864065eda5e2e816',
    ('publication_widgets.py', '_RetainedWatcher.close'): 'a39203a536255e38e7edf4c69d04702dd542f773f1928e6b14b8caf45defd376',
    ('publication_widgets.py', '_protect_native_widget'): 'cba53a09add3fd5a5d3d7f686328302fbb7440d04920ea92c548661b1f0d8030',
    ('publication_widgets.py', '_protect_native_widget.dispatch'): 'd19fc177e9a9bde62f7f98ea4e20dbc70f7656498e06c269328bef639860c9dd',
    ('publication_widgets.py', '_protect_native_widget.dispatch_methods'): '10b456c47e68838d2648e0fbcc036b24935be53a38c26d1a2c07a96485ef8897',
    ('publication_widgets.py', '_protect_native_widget.initialize'): '4ca3c1a9da32da47dbe3b4203c25f485a5c094dc86577e4c023735038776b093',
    ('publication_widgets.py', '_protect_native_widget.post_message'): 'ea00931f053c16705fcde3aeb7b2b3da8f30f171ef5ba06597f2e6ce38ce89dd',
    ('publication_widgets.py', '_protect_native_widget.render'): 'e5af0b5f1cc06d0904bf20371617f054fd6f5f8bf33adf06d2f8dcbcbef496b4',
    ('publication_widgets.py', '_protect_native_widget.render_lines'): '23443c53b369982621aef601f7ca7bcdbdfaf405e2bdf910643fc24679fa5407',
    ('publication_widgets.py', '_protect_native_widget.set_presentation'): '6987f8ebf6c3776ddaf4a185ac5424daa4c0c0838e86b01addea5c1f21897a2b',
    ('publication_widgets.py', '_retained_framework_watcher'): '2365ea2e3c2b2ac7e9f27d554760775d3beb26a69cbf0bee1d65c1d860741eb7',
    ('publication_widgets.py', '_seal_message'): 'e9b892df4ed328ed211200076f4e26d1fae130c4d16f57704c25e869faebfdcb',
    ('cli.py', 'EverywhereGroup.parse_args'): 'd10e78ca848e9299a6b3c9a6efc486a9e2fa02efb3571ec87eb43d045502f87b',
    ('dashboard.py', 'Dashboard.update_data'): 'be12412345ec48f8a805d810ed95bad3ac8e8dca6c14a7074a3adbf956ad9a95',
    ('dashboard.py', 'DashboardPanel.__init__'): '409ebef128440592c40bfb334773b9be8dbc52cd0e4fa4ce91408ac660fe9409',
    ('dashboard.py', 'DashboardPanel.on_key'): '4e4947d10d3b44394cc2bd8e5a6c2bf795610ab5034000b3515bdb00c5b226eb',
    ('dashboard_drill.py', 'DashboardRows.__init__'): '71861003fc89f1c9824934911f00f9be27c4ff4d01894f8e00fa8a414fe05f97',
    ('dashboard_drill.py', 'DashboardRows.action_detail'): 'be88b8ae305223e4235ccb585e5e037f17be96be26d65be2bda676780c185304',
    ('dashboard_drill.py', 'DashboardRows.compose'): '3991c193168e87dcf277f2abf998f66ceb76aebb47995341f731e36699a6d7e6',
    ('dashboard_drill.py', 'DashboardRows.on_mount'): '426ca553cf12cd5b8a3b90300ef467803caeba127ded8e2045585f79a3bc020b',
    ('dashboard_drill.py', 'DashboardRows.open_row'): '6305b433f789d0b5c30f1ab69058549d00da069c877c7d50074f1ceef4aa59af',
    ('dashboard_drill.py', 'DashboardRows.open_selected'): '8db895bcf0cdacd59c656469371aa7e09363430d0957d115702658b5fd198d62',
    ('developer_screens.py', 'DeveloperPicker.__init__'): 'd7082afa3edc5752dd73a59159ce1531cdbc91c6e57a5c4a862b7f962bd246bf',
    ('feature_engine.py', 'FeatureEngine._feature_change'): '5d0686937c2a8b6d45e1d314f3b459c51fd26a516400299ba41dabd2af22d180',
    ('feature_engine.py', 'FeatureEngine.ask'): '54d86e79629def67dffe4fc3c94f5cc09bd28d9309916da1c78f21b87768f968',
    ('feature_engine.py', 'FeatureEngine.boost'): '1330944cf23f58d07a3ab013fac411a3c351685ea35c76e722a9aee0bd2e6170',
    ('feature_engine.py', 'FeatureEngine.capabilities'): '36afa8027962b21361df8685b19a31739c246fe4053c1bf9f67f64f3d3dcea15',
    ('feature_engine.py', 'FeatureEngine.configure_assistant'): '3f434dbc191ac998c9e08c29ada9882a8fbeb2e6250f8cbb162bebb47f6c62b9',
    ('feature_engine.py', 'FeatureEngine.decide_request'): '21e8b11a7f0c6f728b780f4873c40f08c5b64c48f53e4a5609ef507b3da2de32',
    ('feature_engine.py', 'FeatureEngine.disposition'): '68e4f3f3c1ab248d55ec9bbebb46073128aa6e89bc768293a4085a533d0425a2',
    ('feature_engine.py', 'FeatureEngine.mark_notification'): 'c40554bf49170d229e200f253271a7be18cec64d4f4b3812e796b5675a72c5e0',
    ('feature_engine.py', 'FeatureEngine.mode_change'): '05467c10bbda95331999471bbab592b7db6faa0d89855ee53c5ef92600d3ca98',
    ('feature_engine.py', 'FeatureEngine.pin_chart'): '000114661bc0b1069846e0492237457c12422218d723c0bee6f14c87fec39174',
    ('feature_engine.py', 'FeatureEngine.request_budget'): 'c26b85f7722ab365a40b2f0d663dd34a3596b591cf8c02db18bf3649e7e6bcfd',
    ('feature_engine.py', 'FeatureEngine.revoke_boost'): 'a04f79e206de2415dae599719e4c405d4fc0740cee13339ad3dd7bec2cad7c4c',
    ('feature_screens.py', 'ActionForm.__init__'): 'a839a5f3d955014051dd450f48ae4b5901ece173d848d4a99b077db1979889ff',
    ('feature_screens.py', 'ActionForm.compose'): 'cfdf3703927613ca2e76faba1e624ad54fe189f43471b27a28926067b5010996',
    ('group_screens.py', 'GroupPicker.__init__'): '310cb3961ed8fb1379ff8cbe564803d3599bfb8cc9f1afd28c1b19e1fca9e4f0',
    ('principal_ui.py', 'PrincipalUI._bind_engine'): 'e7f6c85caf4d9105aa9fc9f32411883fef36773cd426b30bd04673da4aac7bcf',
    ('principal_ui.py', 'PrincipalUI._clear_principal_state'): 'cdb93970fa0d2e3c5755b9717d1222ca8ef7a14dba27cc6ecb2d913d7c9ae585',
    ('principal_ui.py', 'PrincipalUI._principal_verified'): 'dc4ce10811745e859643ae6b3a1b5ec2f7cba7854bbb6ba174db7f48481825fa',
    ('principal_ui.py', 'PrincipalUI._reject_publication'): 'a6a716000164fea73e837174c283a2ee97eb55e8611d4b95531079c06dc606fc',
    ('principal_ui.py', 'PrincipalUI._synchronize_principal'): 'e881611dec3653234b8b6500ff2d30d79f20b2b5db1f7ff58b90175fdf7891a8',
    ('principal_ui.py', 'PrincipalUI.cached_guard'): '1fd6393674a27300a802545d7f4a996be3223e13db31ea109a75798e52f76f34',
    ('principal_ui.py', 'PrincipalUI.current_guard'): '1b0792264921d6098090e785269f399b4524f675ddaa9eea669e46d68560bbb4',
    ('principal_ui.py', 'PrincipalUI.on_event'): 'f3fe81daef1f596373e495524a50173caba0be62276d25966a7d3fe0a187eb2a',
    ('principal_ui.py', 'PrincipalUI.open_cached_change'): '6dbb72353333971be37c0755ec4bbd45e3dda6d2c8a81628c917704b78bccdb6',
    ('progressive.py', 'ProgressiveRefresh._current_refresh'): '2a1971ab657dac72fb1dd6d40046b841378e281fceeb6f0ddc86cf7b53d6b70a',
    ('progressive.py', 'ProgressiveRefresh._show_read_error'): '727dd4e7af4e44957262fd2f0fc4c5d764aecbf39fce99b1dc4034f3a457e3d0',
    ('progressive.py', 'ProgressiveRefresh._show_wait'): 'e35274ad9da884f67a1096c8e37d4412cdb0189ce315e1e29674510dedf0548d',
    ('progressive.py', 'ProgressiveRefresh._tracked_read'): '04d923bb0665832eb4b1e044ceaf0c1713e7b6b194126220509e98cdd18ae5e9',
    ('progressive.py', 'ProgressiveRefresh.action_refresh'): '0bc1376f510ff9b56eb7875d97678ffd7d6d0bc398a30fc3e21fa8c1047a0ba2',
    ('progressive.py', 'ProgressiveRefresh.load_overview'): '19b05a92adf8c4899251509eb807e4edadbd6b7d5a8f5879482ebdff078f3408',
    ('progressive.py', 'ProgressiveRefresh.load_overview.fetch'): '20d5959d4d45d10d03089c1a952a9ed0362b7c0d5b0306b4c9e9b36d4516ed6b',
    ('progressive.py', 'ProgressiveRefresh.publish_tab'): 'f210a2a794ad60753a042656f1993310c040b4594aaad203e0cf65ddf556ca93',
    ('publication_output.py', 'prompt_number'): '00a172a88ca4a0cc53ea83e07bf62929275633cf8810da9f8b8c18a215f3ccce',
    ('publication_output.py', 'read_text'): '5cc6a57edd8b1c47d8edd88032b1a187b6ef62a362a16936d44748cc7ea72334',
    ('publication_output.py', 'terminal_output'): '1dc19be8472bf998795ed7041aa493fe3518a99d5645a030c062f6d01719f0f9',
    ('publication_output.py', 'write_export'): 'ed1c98a1112af04382a4f171c9212022fd0978d0aa13d3a7b3fe20dc45c1d3d9',
    ('publication_output.py', 'write_renderable'): '0a7da08b6879ad6ba64e7cc770470aecefeb09730acd89b0427dfd90c9cff0c5',
    ('publication_output.py', 'write_text'): '34305acd355c20f676ad8cf2cb4f3717ab12a3be741bfa2d6db1d7279fb32af2',
    ('publication_widgets.py', 'ModalScreen.__init__'): '2355eabda64fc45c39f81323e88c50828c5b7fbd6216c556d03c46deec6dcdaf',
    ('publication_widgets.py', 'PublicationApp._deliver_notifications'): '3c8a091ca7d1122998ae9df2d65c32f4244bdb1612a2cfb6daba6770887b348b',
    ('publication_widgets.py', 'PublicationApp._dispatch_action'): 'b1dadd3415f4d1237c5297abfc2002390df965668a4b2556612b26f6d97eec4d',
    ('publication_widgets.py', 'PublicationApp._handle_exception'): '17a2a5fdac48eea30428de0a1fbe3ac161d051d42318faa5ed765a23729de3be',
    ('publication_widgets.py', 'PublicationApp._on_notify'): '6ce3e052f4a9e35a786c74447c324c8345b69ea4b44ddc75e75fab7834554f6f',
    ('publication_widgets.py', 'PublicationApp._process_messages'): '1a70d38ef83812a221d29a58529462c0df109432ddb9fa5c44cb0e8a265df7f9',
    ('publication_widgets.py', 'PublicationApp._process_messages.handle'): 'd5fd13eff6bfbe900c3a7baf1345d6a26602cee07e40536aca25184e3b65cbd2',
    ('publication_widgets.py', 'PublicationApp._publication_rejected'): 'f84c66cd68baf3a6dcd2f55ee42f477cdf112aff7337baf44cbb14481b552430',
    ('publication_widgets.py', 'PublicationApp._refresh_notifications'): 'b56ba96124f9f7d837eff0ecb1ab4add9595dd5e47ca75d11f0ac278fb4cf504',
    ('publication_widgets.py', 'PublicationApp._register'): 'a68ef34b05b2bc343ea2aa0eacc825be84ce7b103372b63a960d24fdd469ee61',
    ('publication_widgets.py', 'PublicationApp.clear_publication_notifications'): 'dbc84d36715000cb40b502cabd770d496adacc92fdb4bd787766fb63b0687a09',
    ('publication_widgets.py', 'PublicationApp.copy_to_clipboard'): '18f077938eb4cbad65fb1395d4900db5e83305a1bb203eb5329bd23f0329970e',
    ('publication_widgets.py', 'PublicationApp.open_url'): '42505798f856f5d4d189314f3b1e34ae9bf69637609b2551026bbb0c3761b35b',
    ('publication_widgets.py', 'PublicationApp.publish_notification'): '4dae2f23afbeb1a1d2ea7f7b258924583f5c7fa266076b7f61e3090be0531123',
    ('publication_widgets.py', 'PublicationDispatch._dispatch_message'): 'cf41b29ee53a381db26a4c3232c711c0112a18350753d01777e37270f9161880',
    ('publication_widgets.py', 'PublicationWidget.__init__'): '49490e4591b1efad794d640d3b724e6e7266c552e3c665f928e2bb100f1c5de9',
    ('publication_widgets.py', 'PublicationWidget.__setattr__'): '83030a2170f14ea1b59df50eb930dab2df22990d6872371ccf72443481975b46',
    ('publication_widgets.py', 'PublicationWidget._framework_callback'): '8fc30bf7c935793e9933d8220ec9ae25b8e999c9ec31dff018a61f4118d51742',
    ('publication_widgets.py', 'PublicationWidget._framework_callback.run'): '495e9403bc6a9f46cb67439dfd8ea77e173bf9c01072a51a17a72eb1d436a4d0',
    ('publication_widgets.py', 'PublicationWidget._get_dispatch_methods'): '9cf1b253c9985477c598b24681b5d374f8a5c0e59eb72d136cc3d683b1846053',
    ('publication_widgets.py', 'PublicationWidget._publication_rejected'): '7414337ed89ef015d3de4d5ccfc3adf4b293a754862f682ba885410aa4ab189f',
    ('publication_widgets.py', 'PublicationWidget.input_origin'): '36b3d9168fe3273563f8cc6b40b34b86ad7b85fc6c2eed40ad9fccf687f9176e',
    ('publication_widgets.py', '_PublicationToast._discard'): 'eee1437b642c2b25c739f930a4817d550d9811889942895a4bd1402165aa413a',
    ('publication_widgets.py', '_PublicationToast.render'): '0b31b11c2c2537fe7bfa76fe081ae9601a2fcd218badc7a4289dc3d8fbb4cb03',
    ('publication_widgets.py', '_PublicationToast.render_lines'): '84a8274aea26650eb9dbe93ccaa131746c78f94ca0518d922a4fbb3a3066f26f',
    ('screens.py', 'ChangeScreen.__init__'): 'da4d919c9c76d022bfc06293beb0c7f92157a1ef68c79071961ea06672b7c923',
    ('screens.py', 'ChangeScreen.compose'): '529e672af713d7b991b4640c048243fa07cf347540bda62079097192531aa72e',
    ('screens.py', 'DetailScreen.__init__'): 'dd31bf5cb795be5af1c6abba7ced5276e8bd278a80e03c65025473a277b80543',
    ('screens.py', 'DetailScreen.compose'): 'c89c146c6eaaf6df8a9e5e5992123a72478c13ffec37407411084e427dd7913c',
    ('tui.py', 'FinOpsApp.__init__'): 'a87d8917947de9aeb7e48721556bfdbe0e3f7652ebcb7c71b05c32a41a7cb586',
    ('tui.py', 'FinOpsApp._render_tab'): '60b28c3dbafc5a5c82c977964c82917711229265ab2919b84df96c34ef9f860e',
    ('tui.py', 'FinOpsApp.exact_on_focus'): 'fdf137f632ecb8766aa376c600e118cb6e87fa6ea5b3efe859bda17ae80faf1e',
    ('tui.py', 'FinOpsApp.get_line_filters'): '2394c7bf33b07584c30c1f1dfa0b10d9ea280f39fc2fdeca44ecb8d8f55fa31b',
    ('tui.py', 'FinOpsApp.open_detail'): '89b0f5eecb96737f7641a70282bae37c6a11b0093f95b7b3bb74e89848548139',
    ('tui.py', 'FinOpsApp.render_tab'): '5448838e8112922ee13f18c049ccb23b1db127e192ad21e4b2163525f843e301',
    ('tui.py', 'FinOpsApp.selected'): 'aaabeb7380b0aa463cad5ae649b3cb1639a7ff8d358cef8555e4ede5a75aab75',
    ('tui.py', 'FinOpsApp.switched'): '46592e596007cb1659e07e1fe644639635f2ace4ff53b64cf59ce4926053ec4e',
    ('tui.py', 'FinOpsApp.update_access'): 'add588ab82d0da215820a1f1e80d55c6a8c253517b274c25017e48cc4e1c9bdc',
    ('tui.py', 'FinOpsApp.update_brand'): '9806807c341ff6d1aee402ae1caad4c7da676c8433a8e39b90d304d4421f0b8a',
    ('ui_features.py', 'FeatureUI._show_read_detail'): 'aef63453cc8cd45ef32a54395e705da868fc900617262793672c5fa7ec57c974',
    ('ui_features.py', 'FeatureUI.action_assistant_configure.load'): '15fcdb739620f6af70a1129e762b6417abf9df9ca38a18dd352de577b5112d7c',
    ('ui_features.py', 'FeatureUI.action_assistant_history'): 'ae713363bbda7b34407c85306de74c5f085aa9c857f85b54f77eb3dd815172be',
    ('ui_features.py', 'FeatureUI.action_assistant_pins'): '48a823f080ea5e4124798a90154a212397907d3069d12fdf6c521b8ebe53fa0b',
    ('ui_features.py', 'FeatureUI.action_budget_history'): '9d93c3e945b6ec559aa724e6c74f1e5fde24bb2611d4c9f39f72ba45f1ae8266',
    ('ui_features.py', 'FeatureUI.action_copy_request'): 'e6674f18e1b0c65e00a3c0bc7854e358426a9b700c6242b9fb6839d478a368ed',
    ('ui_features.py', 'FeatureUI.action_membership.load'): 'daf81487b8e97e4de1ff9d0fb215bb683be9f724f10dd10f5b82489f0cc70319',
    ('ui_features.py', 'FeatureUI.action_notifications'): '970f5d13a035708e43ca5bbde3ba52ebe6732e659f3cfce65f6c966d5f02e011',
    ('ui_features.py', 'FeatureUI.action_pin_chart'): '42661d673f908a16707f49a6a1505a32e09d4b9771c72d9d55d75f23527b7cc3',
    ('ui_features.py', 'FeatureUI.action_show_boosts'): '77b980e224cc2108aad80a340dbca76b77bf34e60b95df22e82e9356912ab1df',
    ('ui_features.py', 'FeatureUI.activate_profile'): '9350254e40174c17e418b42607c4a37bc6ecc341aff8ddb15091a52e010381b7',
    ('ui_features.py', 'FeatureUI.ask_current'): 'a993530a85f74f65a65c51548bd41089d44da02d89acf952b590f7bdbbf92194',
    ('ui_features.py', 'FeatureUI.push_cached_form'): 'e1654e7510bf051892756abcdcab3564f6f547b34b28aaa3b8c905f46123c2ca',
    ('ui_features.py', 'FeatureUI.refresh_features'): '948b1a3795aa207880802188bab8ba5db8f19a5289f8af08980c78b256665138',
}
ATTRIBUTE_CONTEXTS.update(LIFECYCLE_CONTEXTS)
