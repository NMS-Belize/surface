from django.apps import AppConfig


class WxConfig(AppConfig):
    name = 'wx'

    def ready(self):
        import wx.signals  # This ensures signals are loaded
