from django.db.models.signals import post_save, pre_save
from django.dispatch import receiver
from django.utils.timezone import now, timedelta
from wx.models import Station, Wis2BoxPublish, Wis2BoxPublishLogs

@receiver(post_save, sender=Station)
def update_wis2boxPublish_on_international_exchange_change(sender, instance, **kwargs):
    """
    Ensure Wis2BoxPublish instances are created or deleted when the
    international_exchange field of a Station changes.
    """
    if instance.international_exchange:
        # Create a Wis2Box entry if it is an international excnage staton
        Wis2BoxPublish.objects.get_or_create(station=instance)
    else:
        # Delete the Wis2Box entry if the station no longer has international exchange
        Wis2BoxPublish.objects.filter(station=instance).delete()


@receiver(pre_save, sender=Wis2BoxPublish)
def reset_wis2boxPublish_setting(sender, instance, **kwargs):
    """
    Resets some settings relating to hybrid stations if the hybrid station is deleted
    """
    # If hybrid station is null (the behaviour on delete) and the station isn't a hybrid station, reset booleans
    if instance.hybrid_station is None and instance.hybrid == True:
        instance.publishing = False
        instance.hybrid = False


@receiver(post_save, sender=Wis2BoxPublishLogs)
def update_wis2boxPublish_on_logs_add(sender, instance, **kwargs):
    """
    When a new log is saved:
        1.) Count how many entries exist with success_log=True for the same publish_station.
        2.) Count how many entries exist with success_log=False for the same publish_station.
        3.) Update the publish_success field in the Wis2BoxPublish model where the id is instance.publish_station
            with the count from step 1.
        4.) Update the publish_fail field in the Wis2BoxPublish model where the id is instance.publish_station
            with the count from step 2.
        5.) Delete all entries in Wis2BoxPublishLogs where created_at is older than 24 hours.
    """
    success_count = Wis2BoxPublishLogs.objects.filter(publish_station=instance.publish_station, success_log=True).count()
    fail_count = Wis2BoxPublishLogs.objects.filter(publish_station=instance.publish_station, success_log=False).count()

    # Update the Wis2BoxPublish model with the success and fail counts
    Wis2BoxPublish.objects.filter(id=instance.publish_station.id).update(
        publish_success=success_count, 
        publish_fail=fail_count
    )

    # Delete logs older than 24 hours
    time_threshold = now() - timedelta(hours=24)
    Wis2BoxPublishLogs.objects.filter(created_at__lt=time_threshold).delete()