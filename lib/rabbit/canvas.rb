require "forwardable"
require "gtk2"
require "rd/rdfmt"

require "rabbit/rabbit"
require 'rabbit/element'
require "rabbit/rd2rabbit-lib"
require "rabbit/theme"
require "rabbit/index"
require "rabbit/menu"
require "rabbit/keys"

module Rabbit

  class Canvas
    
    include Enumerable
    extend Forwardable
    include Keys

    BUTTON_PRESS_ACCEPTING_TIME = 0.5 * 1000

   
    def_delegators(:@frame, :icon, :icon=, :set_icon)
    def_delegators(:@frame, :icon_list, :icon_list=, :set_icon_list)
    def_delegators(:@frame, :quit, :logger)
    
    attr_reader :drawing_area, :drawable, :foreground, :background
    attr_reader :theme_name, :font_families
    attr_reader :source

    attr_writer :saved_image_basename

    attr_accessor :saved_image_type


    def initialize(frame)
      @frame = frame
      @theme_name = nil
      @current_cursor = nil
      @blank_cursor = nil
      @saved_image_basename = nil
      clear
      init_drawing_area
      layout = @drawing_area.create_pango_layout("")
      @font_families = layout.context.list_families
      update_menu
    end

    def title
      tp = title_page
      if tp
        tp.title
      else
        "Rabbit"
      end
    end

    def page_title
      return "" if pages.empty?
      page = current_page
      if page.is_a?(Element::TitlePage)
        page.title
      else
        "#{title}: #{page.title}"
      end
    end

    def width
      @drawable.size[0]
    end

    def height
      @drawable.size[1]
    end

    def pages
      if @index_mode
        @index_pages
      else
        @pages
      end
    end
    
    def page_size
      pages.size
    end

    def destroy
      @drawing_area.destroy
    end

    def current_page
      page = pages[current_index]
      if page
        page
      else
        move_to_first
        pages.first
      end
    end

    def current_index
      if @index_mode
        @index_current_index
      else
        @current_index
      end
    end

    def next_page
      pages[current_index + 1]
    end

    def each(&block)
      pages.each(&block)
    end

    def <<(page)
      pages << page
    end

    def apply_theme(name=nil)
      @theme_name = name || @theme_name || default_theme || "default"
      if @theme_name and not @pages.empty?
        clear_theme
        clear_index_pages
        theme = Theme.new(self)
        theme.apply(@theme_name)
        @drawing_area.queue_draw
      end
    end

    def reload_theme
      apply_theme
    end

    def parse_rd(source=nil)
      @source = source || @source
      if @source.modified?
        begin
          keep_index do
            tree = RD::RDTree.new("=begin\n#{@source.read}\n=end\n")
            clear
            visitor = RD2RabbitVisitor.new(self)
            visitor.visit(tree)
            apply_theme
            @frame.update_title(title)
            update_menu
          end
        rescue Racc::ParseError
          logger.warn($!.message)
        end
      end
    end

    def reload_source
      if need_reload_source?
        parse_rd
      end
    end

    def need_reload_source?
      @source and @source.modified?
    end

    def full_path(path)
      @source and @source.full_path(path)
    end

    def tmp_dir_name
      @source and @source.tmp_dir_name
    end

    def set_foreground(color)
      @foreground.set_foreground(color)
    end

    def set_background(color)
      @background.set_foreground(color)
      @drawable.background = color
    end

    def save_as_image
      file_name_format =
          "#{saved_image_basename}%0#{number_of_places(page_size)}d.#{@saved_image_type}"
      each_page_pixbuf do |pixbuf, page_number|
        file_name = file_name_format % page_number
        pixbuf.save(file_name, normalized_saved_image_type)
      end
    end
    
    def each_page_pixbuf
      args = [@drawable, 0, 0, width, height]
      before_page_index = current_index
      pages.each_with_index do |page, i|
        move_to(i)
        @drawable.process_updates(true)
        yield(Gdk::Pixbuf.from_drawable(@drawable.colormap, *args), i)
      end
      move_to(before_page_index)
    end
    
    def fullscreened
      set_cursor(blank_cursor)
    end

    def unfullscreened
      set_cursor(nil)
    end

    def iconified
      # do nothing
    end

    def saved_image_basename
      name = @saved_image_basename || GLib.filename_from_utf8(title)
      if @index_mode
        name + "_index"
      else
        name
      end
    end

    def redraw
      @drawing_area.queue_draw
    end

    def move_to_if_can(index)
      if 0 <= index and index < page_size
        move_to(index)
      end
    end

    def move_to_next_if_can
      move_to_if_can(current_index + 1)
    end

    def move_to_previous_if_can
      move_to_if_can(current_index - 1)
    end

    def move_to_first
      move_to_if_can(0)
    end

    def move_to_last
      move_to(page_size - 1)
    end

    def index_mode?
      @index_mode
    end

    def toggle_index_mode
      if @index_mode
        @drawable.cursor = @current_cursor
        @index_mode = false
      else
        @drawable.cursor = nil
        @index_mode = true
        if @index_pages.empty?
          @index_pages = Index.make_index_pages(self)
        end
        move_to(0)
      end
      update_menu
      @drawing_area.queue_draw
    end

    private
    def update_menu
      @menu = Menu.new(self)
    end
    
    def clear
      clear_pages
      clear_index_pages
      clear_button_handler
    end
    
    def clear_pages
      @current_index = 0
      @pages = []
    end
    
    def clear_index_pages
      @index_mode = false
      @index_current_index = 0
      @index_pages = []
    end

    def clear_button_handler
      @button_handler_thread = nil
      @button_handler = []
    end
    
    def clear_theme
      @pages.each do |page|
        page.clear_theme
      end
    end

    def keep_index
      index = @current_index
      index_index = @index_current_index
      yield
      @current_index = index
      @index_current_index = index_index
    end
    
    def title_page
      @pages.find{|x| x.is_a?(Element::TitlePage)}
    end

    def default_theme
      tp = title_page
      tp and tp.theme
    end

    def init_drawing_area
      @drawing_area = Gtk::DrawingArea.new
      @drawing_area.set_can_focus(true)
      @drawing_area.add_events(Gdk::Event::BUTTON_PRESS_MASK)
      set_realize
      set_key_press_event
      set_button_press_event
      set_expose_event
      set_scroll_event
    end

    def set_realize
      @drawing_area.signal_connect("realize") do |widget, event|
        @drawable = widget.window
        @foreground = Gdk::GC.new(@drawable)
        @background = Gdk::GC.new(@drawable)
        @background.set_foreground(widget.style.bg(Gtk::STATE_NORMAL))
      end
    end

    def set_key_press_event
      @drawing_area.signal_connect("key_press_event") do |widget, event|
        handled = false
        
        if event.state.control_mask?
          handled = handle_key_with_control(event)
        end
        
        unless handled
          handle_key(event)
        end
      end
    end

    BUTTON_PRESS_HANDLER = {
      Gdk::Event::Type::BUTTON_PRESS => "handle_button_press",
      Gdk::Event::Type::BUTTON2_PRESS => "handle_button2_press",
      Gdk::Event::Type::BUTTON3_PRESS => "handle_button3_press",
    }
    
    def set_button_press_event
      @drawing_area.signal_connect("button_press_event") do |widget, event|
        if BUTTON_PRESS_HANDLER.has_key?(event.event_type)
          __send__(BUTTON_PRESS_HANDLER[event.event_type], event)
          start_button_handler
        end
      end
    end

    def set_expose_event
      prev_width = prev_height = nil
      @drawing_area.signal_connect("expose_event") do |widget, event|
        reload_source
        if @drawable
          if prev_width.nil? or prev_height.nil? or
              [prev_width, prev_height] != [width, height]
            clear_index_pages
            reload_theme
            prev_width, prev_height = width, height
          end
        end
        page = current_page
        if page
          page.draw(self)
#           if next_page
#             next_page.draw(self, true)
#           end
          @frame.update_title(page_title)
        end
      end
    end

    def set_scroll_event
      @drawing_area.signal_connect("scroll_event") do |widget, event|
        case event.direction
        when Gdk::EventScroll::Direction::UP
          move_to_previous_if_can
        when Gdk::EventScroll::Direction::DOWN
          move_to_next_if_can
        end
      end
    end

    def set_current_index(new_index)
      if @index_mode
        @index_current_index = new_index
      else
        @current_index = new_index
      end
    end

    def with_index_mode(new_value)
      current_index_mode = @index_mode
      @index_mode = new_value
      yield
      @index_mode = current_index_mode
    end
    
    def move_to(index)
      set_current_index(index)
      @frame.update_title(page_title)
      @drawing_area.queue_draw
    end

    def set_cursor(cursor)
      @current_cursor = @drawable.cursor = cursor
    end
    
    def calc_page_number(key_event, base)
      val = key_event.keyval
      val += 10 if key_event.state.control_mask?
      val += 20 if key_event.state.mod1_mask?
      val - base
    end

    def normalized_saved_image_type
      case @saved_image_type
      when /jpg/i
        "jpeg"
      else
        @saved_image_type.downcase
      end
    end

    def blank_cursor
      if @blank_cursor.nil?
        source = Gdk::Pixmap.new(@drawable, 1, 1, 1)
        mask = Gdk::Pixmap.new(@drawable, 1, 1, 1)
        fg = @foreground.foreground
        bg = @background.foreground
        @blank_cursor = Gdk::Cursor.new(source, mask, fg, bg, 1, 1)
      end
      @blank_cursor
    end

    def number_of_places(num)
      n = 1
      target = num
      while target >= 10
        target /= 10
        n += 1
      end
      n
    end

    def handle_key(key_event)
      case key_event.keyval
      when *QUIT_KEYS
        quit
      when *MOVE_TO_NEXT_KEYS
        move_to_next_if_can
      when *MOVE_TO_PREVIOUS_KEYS
        move_to_previous_if_can
      when *MOVE_TO_FIRST_KEYS
        move_to_first
      when *MOVE_TO_LAST_KEYS
        move_to_last
      when Gdk::Keyval::GDK_0,
      Gdk::Keyval::GDK_1,
      Gdk::Keyval::GDK_2,
      Gdk::Keyval::GDK_3,
      Gdk::Keyval::GDK_4,
      Gdk::Keyval::GDK_5,
      Gdk::Keyval::GDK_6,
      Gdk::Keyval::GDK_7,
      Gdk::Keyval::GDK_8,
      Gdk::Keyval::GDK_9
        move_to_if_can(calc_page_number(key_event, Gdk::Keyval::GDK_0))
      when Gdk::Keyval::GDK_KP_0,
      Gdk::Keyval::GDK_KP_1,
      Gdk::Keyval::GDK_KP_2,
      Gdk::Keyval::GDK_KP_3,
      Gdk::Keyval::GDK_KP_4,
      Gdk::Keyval::GDK_KP_5,
      Gdk::Keyval::GDK_KP_6,
      Gdk::Keyval::GDK_KP_7,
      Gdk::Keyval::GDK_KP_8,
      Gdk::Keyval::GDK_KP_9
        move_to_if_can(calc_page_number(key_event, Gdk::Keyval::GDK_KP_0))
      when *TOGGLE_FULLSCREEN_KEYS
        @frame.toggle_fullscreen
        reload_theme
      when *RELOAD_THEME_KEYS
        reload_theme
      when *SAVE_AS_IMAGE_KEYS
        save_as_image
      when *ICONIFY_KEYS
        @frame.iconify
      when *TOGGLE_INDEX_MODE_KEYS
        toggle_index_mode
      end
    end

    def handle_key_with_control(key_event)
      handled = false
      case key_event.keyval
      when *Control::REDRAW_KEYS
        redraw
        handled = true
      end
      handled
    end

    def handle_button_press(event)
      case event.button
      when 1, 5
        add_button_handler do
          move_to_next_if_can
        end
      when 2, 4
        add_button_handler do
          move_to_previous_if_can
        end
      when 3
        @menu.popup(event.button, event.time)
      end
    end
    
    def handle_button2_press(event)
      add_button_handler do
        if @index_mode
          index = current_page.page_number(self, event.x, event.y)
          if index
            toggle_index_mode
            move_to_if_can(index)
          end
        end
        clear_button_handler
      end
    end
    
    def handle_button3_press(event)
      add_button_handler do
        clear_button_handler
      end
    end

    def add_button_handler(handler=Proc.new)
      @button_handler.push(handler)
    end
    
    def call_button_handler
      @button_handler.pop.call until @button_handler.empty?
    end

    def start_button_handler
      Gtk.timeout_add(BUTTON_PRESS_ACCEPTING_TIME) do
        call_button_handler
        false
      end
    end
    
  end

end
