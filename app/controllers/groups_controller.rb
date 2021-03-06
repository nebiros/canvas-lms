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

class GroupsController < ApplicationController  
  before_filter :get_context
  before_filter :require_context, :only => [:create_category, :delete_category]
  before_filter :get_group_as_context, :only => [:show]
  
  def context_group_members
    @group = @context
    if authorized_action(@group, @current_user, :manage)
      respond_to do |format|
        format.json { render :json => @group.members_json_cached }
      end
    end
  end
  
  def unassigned_members
    category = @context.group_categories.find_by_id(params[:category_id])
    return render :json => {}, :status => :not_found unless category
    page = (params[:page] || 1).to_i rescue 1
    if category && !category.student_organized?
      groups = category.groups.active
    else
      groups = []
    end
    users = @context.paginate_users_not_in_groups(groups, page)
    
    if authorized_action(@context, @current_user, :manage)
      respond_to do |format|
        format.json { render :json => {
          :pages => users.total_pages,
          :current_page => users.current_page,
          :next_page => users.next_page,
          :previous_page => users.previous_page,
          :total_entries => users.total_entries,
          :pagination_html => render_to_string(:partial => 'user_pagination', :locals => { :users => users }),
          :users => users.map do |u|
            h = { :user_id => u.id, :name => u.last_name_first }
            if @context.is_a?(Course) && (section = u.section_for_course(@context))
              h = h.merge(:section_id => section.id, :section_code => section.section_code)
            end
            h
          end
        } }
      end
    end
  end
  
  def index
    return context_index if @context
    @groups = @current_user ? @current_user.groups.active : []
  end

  def show
    if @group.deleted? && @group.context
      flash[:notice] = t('notices.already_deleted', "That group has been deleted")
      redirect_to named_context_url(@group.context, :context_url)
      return
    end
    @current_conferences = @group.web_conferences.select{|c| c.active? && c.users.include?(@current_user) } rescue []
    @groups = @current_user.group_memberships_for(@group.context) if @current_user
    if @group.free_association?(@current_user)
      if params[:join]
        @group.request_user(@current_user)
        if !@group.grants_right?(@current_user, session, :read)
          render :action => 'membership_pending'
          return
        else
          flash[:notice] = t('notices.welcome', "Welcome to the group %{group_name}!", :group_name => @group.name)
          redirect_to named_context_url(@group.context, :context_groups_url)
          return
        end
      end
      if params[:leave]
        membership = @group.membership_for_user(@current_user)
        if membership
          membership.destroy
          flash[:notice] = t('notices.goodbye', "You have removed yourself from the group %{group_name}.", :group_name => @group.name)
          redirect_to named_context_url(@group.context, :context_groups_url)
          return
        end
      end
    end
    if authorized_action(@group, @current_user, :read)
      @home_page = WikiNamespace.default_for_context(@group).wiki.wiki_page
      respond_to do |format|
        format.html
        format.xml  { render :xml => @group.to_xml }
      end
    end
  end

  def new
    if authorized_action(@context, @current_user, :manage_groups)
      @group = @context.groups.build
    end
  end

  def create_category
    if authorized_action(@context, @current_user, :manage_groups)
      @group_category = @context.group_categories.build
      if populate_group_category_from_params
        create_default_groups_in_category
        flash[:notice] = t('notices.create_category_success', 'Category was successfully created.')
        render :json => [@group_category.as_json, @group_category.groups.map{ |g| g.as_json(:include => :users) }].to_json
      end
    end
  end
  
  def update_category
    if authorized_action(@context, @current_user, :manage_groups)
      @group_category = @context.group_categories.find_by_id(params[:category_id])
      return render(:json => { 'status' => 'not found' }, :status => :not_found) unless @group_category
      return render(:json => { 'status' => 'unauthorized' }, :status => :unauthorized) if @group_category.protected?
      if populate_group_category_from_params
        flash[:notice] = t('notices.update_category_success', 'Category was successfully updated.')
        render :json => @group_category.to_json
      end
    end
  end
  
  def delete_category
    if authorized_action(@context, @current_user, :manage_groups)
      @group_category = @context.group_categories.find_by_id(params[:category_id])
      return render(:json => { 'status' => 'not found' }, :status => :not_found) unless @group_category
      return render(:json => { 'status' => 'unauthorized' }, :status => :unauthorized) if @group_category.protected?
      if @group_category.destroy
        flash[:notice] = t('notices.delete_category_success', "Category successfully deleted")
        render :json => {:deleted => true}
      else
        render :json => {:deleted => false}
      end
    end
  end
  
  def add_user
    @group = @context
    if authorized_action(@group, @current_user, :manage)
      @membership = @group.add_user(User.find(params[:user_id]))
      if @membership.valid?
        @group.touch
        render :json => @membership.to_json
      else
        render :json => @membership.errors.to_json, :status => :bad_request
      end
    end
  end
  
  def remove_user
    @group = @context
    if authorized_action(@group, @current_user, :manage)
      @membership = @group.group_memberships.find_by_user_id(params[:user_id])
      @membership.group_id = nil
      @membership.destroy
      @group.touch
      render :json => @membership.to_json
    end
  end

  def create
    if params[:group]
      group_category_id = params[:group].delete :group_category_id
      if group_category_id && @context.grants_right?(@current_user, session, :manage_groups)
        group_category = @context.group_categories.find_by_id(group_category_id)
        return render :json => {}, :status => :bad_request unless group_category
        params[:group][:group_category] = group_category
      else
        params[:group][:group_category] = nil
      end
    end
    @group = @context.groups.build(params[:group])
    if authorized_action(@group, @current_user, :create)
      respond_to do |format|
        if @group.save
          if !@context.grants_right?(@current_user, session, :manage_groups)
            @group.add_user(@current_user)
          end
          @group.invitees = params[:invitees]
          flash[:notice] = t('notices.create_success', 'Group was successfully created.')
          format.html { redirect_to group_url(@group) }
          format.xml  { head :created, :location => group_url(@group) }
          format.json { render :json => @group.to_json }
        else
          format.html { render :action => "new" }
          format.xml  { render :xml => @group.errors.to_xml }
          format.json { render :json => @group.errors.to_json }
        end
      end
    end
  end

  def edit
    @group = (@context ? @context.groups : Group).find(params[:id])
    @context = @group
    if authorized_action(@group, @current_user, :update)
    end
  end

  def update
    @group = (@context ? @context.groups : Group).find(params[:id])
    if params[:group] && params[:group][:group_category_id]
      group_category_id = params[:group].delete :group_category_id
      group_category = @context.group_categories.find_by_id(group_category_id)
      return render :json => {}, :status => :bad_request unless group_category
      params[:group][:group_category] = group_category
    end
    if authorized_action(@group, @current_user, :manage)
      respond_to do |format|
        if @group.update_attributes(params[:group])
          flash[:notice] = t('notices.update_success', 'Group was successfully updated.')
          format.html { redirect_to group_url(@group) }
          format.json { render :json => @group.to_json }
          format.xml  { head :ok }
        else
          format.html { render :action => "edit" }
          format.json { render :json => @group.errors.to_json }
          format.xml  { render :xml => @group.errors.to_xml }
        end
      end
    end
  end

  def destroy
    @group = (@context ? @context.groups : Group).find(params[:id])
    if authorized_action(@group, @current_user, :manage)
      begin
        @group.destroy
        flash[:notice] = t('notices.delete_success', "Group successfully deleted")
        respond_to do |format|
          format.html { redirect_to(dashboard_url) }
          format.xml  { head :ok }
          format.json { render :json => @group.to_json }
        end
      rescue Exception => e
        respond_to do |format|
          format.html { redirect_to(dashboard_url) }
          format.xml  { render :xml => @group.to_xml }
          format.json { render :json => @group.to_json, :status => :bad_request }
        end
      end
    end
  end

  def public_feed
    return unless get_feed_context(:only => [:group])
    feed = Atom::Feed.new do |f|
      f.title = t(:feed_title, "%{course_or_account_name} Feed", :course_or_account_name => @context.full_name)
      f.links << Atom::Link.new(:href => named_context_url(@context, :context_url))
      f.updated = Time.now
      f.id = named_context_url(@context, :context_url)
    end
    @entries = []
    @entries.concat @context.calendar_events.active
    @entries.concat @context.discussion_topics.active
    @entries.concat WikiNamespace.default_for_context(@context).wiki.wiki_pages.select{|p| !p.new_record?}
    @entries = @entries.sort_by{|e| e.updated_at}
    @entries.each do |entry|
      feed.entries << entry.to_atom(:context => @context)
    end
    respond_to do |format|
      format.atom { render :text => feed.to_xml }
    end
  end

  protected

  def get_group_as_context
    @group = (@context ? @context.groups : Group).find(params[:id])
    if @group && @group.context
      add_crumb @group.context.short_name, named_context_url(@group.context, :context_url)
      add_crumb @group.short_name, named_context_url(@group, :context_url)
    elsif @group
      add_crumb @group.short_name, named_context_url(@group, :context_url)
    end
    @context = @group
  end

  def context_index
    add_crumb (@context.is_a?(Account) ? t('#crumbs.users', "Users") : t('#crumbs.people', "People")), named_context_url(@context, :context_users_url)
    add_crumb t('#crumbs.groups', "Groups"), named_context_url(@context, :context_groups_url)
    @active_tab = @context.is_a?(Account) ? "users" : "people"
    @groups = @context.groups.active
    @categories = @context.group_categories
    group_ids = @groups.map(&:id)

    @user_groups = @current_user.group_memberships_for(@context).select{|g| group_ids.include?(g.id) } if @current_user
    @user_groups ||= []

    @available_groups = (@groups - @user_groups).select{|g| g.free_association?(@current_user) }
    if !@context.grants_right?(@current_user, session, :manage_groups)
      @groups = @user_groups
    end
    # sort by name, but with the student organized category in the back
    @categories = @categories.sort_by{|c| [ (c.student_organized? ? 1 : 0), c.name ] }
    @groups = @groups.sort_by{ |g| [(g.name || '').downcase, g.created_at]  }
    
    if authorized_action(@context, @current_user, :read_roster)
      respond_to do |format|
        if @context.grants_right?(@current_user, session, :manage_groups)
          format.html { render :action => 'context_manage_groups' }
        else
          format.html { render :action => 'context_groups' }
        end
        format.xml  { render :xml => @groups.to_xml }
        format.atom { render :xml => @groups.to_atom.to_xml }
      end
    end
  end

  def populate_group_category_from_params
    name = params[:category][:name] || @group_category.name
    name = t(:default_category_title, "Study Groups") if name.blank?
    if GroupCategory.protected_name_for_context?(name, @context)
      render :json => { 'category[name]' => t('errors.category_name_reserved', "%{category_name} is a reserved name.", :category_name => name) }, :status => :bad_request
      return false
    elsif @context.group_categories.other_than(@group_category).find_by_name(name)
      render :json => { 'category[name]' => t('errors.category_name_unavailable', "%{category_name} is already in use.", :category_name => name) }, :status => :bad_request
      return false
    end

    enable_self_signup = params[:category][:enable_self_signup] == "1"
    restrict_self_signup = params[:category][:restrict_self_signup] == "1"
    if enable_self_signup && restrict_self_signup && @group_category.has_heterogenous_group?
      render :json => { 'category[restrict_self_signup]' => t('errors.cant_restrict_self_signup', "Can't enable while a mixed-section group exists in the category.") }, :status => :bad_request
      return false
    end

    @group_category.name = name
    @group_category.configure_self_signup(enable_self_signup, restrict_self_signup)
    @group_category.save
  end
  
  def create_default_groups_in_category
    self_signup = params[:category][:enable_self_signup] == "1"
    distribute_students = !self_signup && params[:category][:split_groups] == "1"
    return unless self_signup || distribute_students

    count_field = self_signup ? :create_group_count : :split_group_count
    count = params[:category][count_field].to_i
    count = 0 if count < 0
    count = @context.students.length if distribute_students && count > @context.students.length
    return if count.zero?

    # TODO i18n
    group_name = @group_category.name
    group_name = group_name.singularize if I18n.locale == :en
    count.times do |idx|
      @group_category.groups.create(:name => "#{group_name} #{idx + 1}", :context => @context)
    end

    if distribute_students
      @students = @context.students.sort_by{|s| rand}
      @students.each_index do |idx|
        @group_category.groups[idx % count].add_user(@students[idx])
      end
    end
  end
end
