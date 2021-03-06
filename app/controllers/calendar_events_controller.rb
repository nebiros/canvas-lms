#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

class CalendarEventsController < ApplicationController
  before_filter :require_context
  
  add_crumb(proc { t(:'#crumbs.calendar_events', "Calendar Events")}, :only => [:show, :new, :edit]) { |c| c.send :calendar_url_for, c.instance_variable_get("@context") }
  
  
  def show
    @event = @context.calendar_events.find(params[:id])
    add_crumb(@event.title, named_context_url(@context, :context_calendar_event_url, @event))
    if @event.deleted?
      flash[:notice] = t 'notices.deleted', "This event has been deleted"
      redirect_to calendar_url_for(@context)
      return
    end
    if authorized_action(@event, @current_user, :read)
      log_asset_access(@event, "calendar", "calendar")
      respond_to do |format|
        format.html { render :action => 'new' }
        format.xml  { render :xml => @event.to_xml }
        format.json { render :json => @event.to_json(:permissions => {:user => @current_user, :session => session}) }
      end
    end
  end


  def new
    @event = @context.calendar_events.build
    add_crumb(t('crumbs.new', "New Calendar Event"), named_context_url(@context, :new_context_calendar_event_url))
    @event.start_at = params[:start_at]
    @event.end_at = params[:end_at]
    @event.title = params[:title]
    @editing = true
    authorized_action(@event, @current_user, :create)
  end

  def create
    params[:calendar_event][:time_zone_edited] = Time.zone.name if params[:calendar_event]
    @event = @context.calendar_events.build(params[:calendar_event])
    if authorized_action(@event, @current_user, :create)
      respond_to do |format|
        @event.content_being_saved_by(@current_user)
        if @event.save
          flash[:notice] = t 'notices.created', "Event was successfully created."
          format.html { redirect_to calendar_url_for(@context) }
          format.xml  { head :created, :location => named_context_url(@context, :context_calendar_url) }
          format.json { render :json => @event.to_json(:permissions => {:user => @current_user, :session => session}), :status => :created}
        else
          format.html { render :action => "new" }
          format.xml  { render :xml => @event.errors.to_xml }
          format.json { render :json => @event.errors.to_json, :status => :bad_request }
        end
      end
    end
  end

  def edit
    @event = @context.calendar_events.find(params[:id])
    if @event.grants_right?(@current_user, session, :update)
      @event.start_at = params[:start_at] if params[:start_at]
      @event.end_at = params[:end_at] if params[:end_at]
      @event.title = params[:title] if params[:title]
    end
    @editing = true
    if authorized_action(@event, @current_user, :update_content)
      render :action => 'new'
    end
  end

  def update
    @event = @context.calendar_events.find(params[:id])
    if authorized_action(@event, @current_user, :update)
      respond_to do |format|
        params[:calendar_event][:time_zone_edited] = Time.zone.name if params[:calendar_event]
        @event.content_being_saved_by(@current_user)
        if @event.update_attributes(params[:calendar_event])
          log_asset_access(@event, "calendar", "calendar", 'participate')
          flash[:notice] = t 'notices.updated', "Event was successfully updated."
          format.html { redirect_to calendar_url_for(@context) }
          format.xml  { head :ok }
          format.json { render :json => @event.to_json(:permissions => {:user => @current_user, :session => session}), :status => :ok }
        else
          format.html { render :action => "edit" }
          format.xml  { render :xml => @event.errors.to_xml }
          format.json { render :json => @event.errors.to_json, :status => :bad_request }
        end
      end
    end
  end

  def destroy
    @event = @context.calendar_events.find(params[:id])
    if authorized_action(@event, @current_user, :delete)
      @event.destroy
      respond_to do |format|
        format.html { redirect_to calendar_url_for(@context) }
        format.xml  { head :ok }
        format.json { render :json => @event.to_json, :status => :ok }
      end
    end
  end

end
