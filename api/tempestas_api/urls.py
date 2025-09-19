from django.conf.urls import url, include
from django.contrib import admin
from rest_framework_simplejwt.views import (
    TokenObtainPairView,
    TokenRefreshView,
)
from django.urls import path, include

from .views import change_password

urlpatterns = [
    path('accounts/', include('django.contrib.auth.urls')),
    path('api-auth/', include('rest_framework.urls', namespace='rest_framework')),
    path('api/token/', TokenObtainPairView.as_view(), name='token_obtain_pair'),
    path('api/token/refresh/', TokenRefreshView.as_view(), name='token_refresh'),
    path('password/', change_password, name='change_password'),
    path('admin/', admin.site.urls),
    path('', include('wx.urls')),
]

admin.site.site_header = 'Surface Admin Area'
admin.site.site_title = admin.site.site_header
