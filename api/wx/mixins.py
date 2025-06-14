from django.conf import settings
from django.contrib.auth.mixins import PermissionRequiredMixin
from django.urls import reverse
from django.contrib.auth import REDIRECT_FIELD_NAME
from django.shortcuts import redirect
from django.core.exceptions import PermissionDenied
from wx.models import WxPermission, WxGroupPermission


class WxPermissionRequiredMixin(PermissionRequiredMixin):
    """
    A subclass of Django's PermissionRequiredMixin that checks
    custom WxPermission/WxGroupPermission tables instead of auth_permission.
    You must set `permission_required = "<permission_name>"` (e.g. "station-create").
    """

    def has_permission(self):
        """
        Override the default `has_permission` to check if WxPermission in WxGroupPermission.
        Returns True if:
         1) The user is authenticated, AND
         2) At least one of the user's groups has a related WxGroupPermission
            whose `permissions__name` matches a name in `self.permission_required`.
        Otherwise, returns False.
        """

        user = self.request.user

        # If not logged in, fail immediately
        if not user.is_authenticated:
            return False

        # Superuser shortcut
        if user.is_superuser:
            return True

        # Normalize permission_required into a tuple
        perms = self.get_permission_required()
        if isinstance(perms, str):
            perms = (perms,)

        # Grab all group IDs the user belongs to
        user_group_ids = user.groups.values_list("id", flat=True)

        # Treat permissions as OR: As soon as we find one matching permission, return True.
        for perm_name in perms:
            # Try to look up the corresponding WxPermission row
            try:
                perm_obj = WxPermission.objects.get(name=perm_name)
            except WxPermission.DoesNotExist:
                # If you’d rather treat “missing in DB” as simply “not granted,”
                # you could `continue` here instead of raising. But raising
                # can help catch typos.
                raise PermissionDenied(f"WxPermission '{perm_name}' not found in DB.")

            # Check if any of the user’s groups has this permission
            if WxGroupPermission.objects.filter(
                group_id__in=user_group_ids,
                permissions=perm_obj
            ).exists():
                # As soon as one is satisfied, allow access
                return True

        return False
    
    def handle_no_permission(self):
        """
        If the user is not logged in, redirect to LOGIN_URL with ?next=<current_path>.
        If the user is logged in but lacks permissions, raise 403 (PermissionDenied).
        This mirrors PermissionRequiredMixin's default behavior when `raise_exception=True`.
        """
        # If user is not authenticated, send to login page
        user = self.request.user
        if not user.is_authenticated:
            login_url = self.get_login_url()
            return redirect(f"{login_url}?{REDIRECT_FIELD_NAME}={self.request.get_full_path()}")

        # Otherwise, User is logged in but lacks perms, so redirect to 'not-auth'
        not_auth_url = reverse('not-auth')
        return redirect(not_auth_url)

    def get_login_url(self):
        """
        Let PermissionRequiredMixin know which login URL (sending the user back to the login page) to use.
        By default, it looks at `self.login_url` or `settings.LOGIN_URL`.
        """
        if getattr(self, "login_url", None):
            return self.login_url
        return settings.LOGOUT_REDIRECT_URL
