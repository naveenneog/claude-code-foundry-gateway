"""Reviewed P85 lifecycle effects, bound to exact expressions and source contexts."""

ATTRIBUTE_EXCEPTIONS = {
    ('developer_screens.py', 'DeveloperPicker.open_remove_form', 'app.switch_screen'):
        'Replaces the picker with a protected ActionForm under the retained directory origin; construction and registration refuse expired content.',
    ('developer_screens.py', 'DeveloperPicker.open_remove_form', 'app._error_text'):
        'Formats only the safe domain refusal for the protected directory status under the explicit local-message guard.',
    ('developer_screens.py', 'DeveloperPicker.open_add_form', 'self.app.switch_screen'):
        'Replaces the picker under both directory and catalog origins; the protected form and registration retain those same sources.',
    ('tui.py', 'FinOpsApp.exit', 'super().exit(result, return_code=return_code, message=message)'):
        'After application-owned writes finish, forwards only to PublicationApp.exit, which still refuses every raw farewell message.',
    ('tui.py', 'FinOpsApp.saving', 'self._active_mutations'):
        'Reads only the application-owned task registry to return a local boolean; no task, payload or output capability escapes.',
    ('tui.py', 'FinOpsApp.run_mutation', 'self._active_mutations'):
        'Registers the write before awaiting it so cancellation or quit cannot abandon its completion and receipt.',
    ('tui.py', 'FinOpsApp.run_mutation', 'task.add_done_callback'):
        'Both registered callbacks are guarded_deferred wrappers in this exact context; raw deferred callbacks remain unapproved elsewhere.',
    ('tui.py', 'FinOpsApp.run_mutation', 'self._mutation_finished'):
        'Binds the application-owned completion handler only through a retained local-message callback, never a raw output callback.',
    ('tui.py', 'FinOpsApp.run_mutation', 'asyncio.shield'):
        'Shields only the registered operation from modal cancellation; each data-bearing publication still checks its originating source.',
    ('tui.py', 'FinOpsApp.run_mutation', 'asyncio.CancelledError'):
        'Recognizes modal cancellation solely to install guarded orphan handling and re-raise; it does not swallow operation failures.',
    ('tui.py', 'FinOpsApp.run_mutation', 'self._orphaned_mutation'):
        'Binds the cancelled modal completion handler through guarded_deferred so publication refusals reach the safe application boundary.',
    ('tui.py', 'FinOpsApp._mutation_finished', 'self._active_mutations'):
        'Removes only the completed owned task before deciding whether a successful sign-out can finish exiting.',
    ('tui.py', 'FinOpsApp._mutation_finished', 'task.cancelled'):
        'Checks completion state before reading a task result; cancelled work never becomes successful sign-out intent.',
    ('tui.py', 'FinOpsApp._mutation_finished', 'task.exception'):
        'Checks whether the owned task failed without rendering its exception; only a successful sign-out result requests exit.',
    ('tui.py', 'FinOpsApp._mutation_finished', 'self._signout_complete'):
        'Retains successful sign-out intent until the owned registry is empty; the flag carries no backend content.',
    ('tui.py', 'FinOpsApp._orphaned_mutation', 'task.cancelled'):
        'Distinguishes cancellation from a completed orphan failure without obtaining or rendering a payload.',
    ('tui.py', 'FinOpsApp._orphaned_mutation', 'task.exception'):
        'Retrieves only the owned task failure for the existing safe application exception boundary, never a raw console or log.',
    ('tui.py', 'FinOpsApp._orphaned_mutation', 'self._handle_exception'):
        'Delegates orphan failures to PublicationApp so publication refusals bypass payload-bearing fatal diagnostics; unrelated failures remain visible.',
}

ATTRIBUTE_CONTEXTS = {
    ('developer_screens.py', 'DeveloperPicker.open_remove_form'): '9393909584c2a0abd3811ea3326e7f32d8230df681fff41cd91096727654c8d2',
    ('tui.py', 'FinOpsApp.exit'): '0eca6d4250b8710094eaaa8e70580877c24e3355105e486982bd06668431c611',
    ('tui.py', 'FinOpsApp.saving'): '44059bf94d3104848136e785f478afbcceee274b20f58b1ba2b0e52a101fd007',
    ('tui.py', 'FinOpsApp.run_mutation'): 'dfd8fa28b3de4eb3cecb89af356b8c8fd338d7e3098f138f4b2815f795a305cb',
    ('tui.py', 'FinOpsApp._mutation_finished'): '20e401cd209dc90b4c1dd798fdb1075b3c362fc29052d4f25b641993a5fc6163',
    ('tui.py', 'FinOpsApp._orphaned_mutation'): '86a86430a3d13af73b02302bef2aab93d2681a85aa819b651305319faf1f7516',
}
