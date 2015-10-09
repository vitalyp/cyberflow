# encoding: utf-8

require 'redcarpet'
require 'nokogiri'

class Markdown
  class Renderer < Redcarpet::Render::HTML
    def initialize(options={})
      super
    end

    def block_code(code, language)
      <<-HTML
<div class="code_container">
<pre class="brush: #{brush_for(language)}; gutter: false; toolbar: false">
#{ERB::Util.h(code)}
</pre>
</div>
      HTML
    end

    def header(text, header_level)
      # Always increase the heading level by, so we can use h1, h2 heading in the document
      header_level += 1

      %(<h#{header_level}>#{text}</h#{header_level}>)
    end

    def paragraph(text)
      if text =~ /^(TIP|IMPORTANT|CAUTION|WARNING|NOTE|INFO|TODO)[.:](.*?)/
        convert_notes(text)
      elsif text =~ /^\[<sup>(\d+)\]:<\/sup> (.+)$/
        linkback = %(<a href="#footnote-#{$1}-ref"><sup>#{$1}</sup></a>)
        %(<p class="footnote" id="footnote-#{$1}">#{linkback} #{$2}</p>)
      else
        text = convert_footnotes(text)
        "<p>#{text}</p>"
      end
    end

    private

    def convert_footnotes(text)
      text.gsub(/\[<sup>(\d+)\]<\/sup>/i) do
        %(<sup class="footnote" id="footnote-#{$1}-ref">) +
            %(<a href="#footnote-#{$1}">#{$1}</a></sup>)
      end
    end

    def brush_for(code_type)
      case code_type
        when 'ruby', 'sql', 'plain'
          code_type
        when 'erb'
          'ruby; html-script: true'
        when 'html'
          'xml' # html is understood, but there are .xml rules in the CSS
        else
          'plain'
      end
    end

    def convert_notes(body)
      # The following regexp detects special labels followed by a
      # paragraph, perhaps at the end of the document.
      #
      # It is important that we do not eat more than one newline
      # because formatting may be wrong otherwise. For example,
      # if a bulleted list follows the first item is not rendered
      # as a list item, but as a paragraph starting with a plain
      # asterisk.
      body.gsub(/^(TIP|IMPORTANT|CAUTION|WARNING|NOTE|INFO|TODO)[.:](.*?)(\n(?=\n)|\Z)/m) do
        css_class = case $1
                      when 'CAUTION', 'IMPORTANT'
                        'warning'
                      when 'TIP'
                        'info'
                      else
                        $1.downcase
                    end
        %(<div class="#{css_class}"><p>#{$2.strip}</p></div>)
      end
    end
  end
end

class Markdown
  def initialize(view, layout)
    @view = view
    @layout = layout
    @index_counter = Hash.new(0)
    @raw_header = ''
    @node_ids = {}
  end

  def render(body)
    @raw_body = body
    extract_raw_header_and_body
    generate_header
    generate_title
    generate_body
    generate_structure
    generate_index
    render_page
  end

  private

  def dom_id(nodes)
    dom_id = dom_id_text(nodes.last.text)

    # Fix duplicate node by prefix with its parent node
    if @node_ids[dom_id]
      if @node_ids[dom_id].size > 1
        duplicate_nodes = @node_ids.delete(dom_id)
        new_node_id = "#{duplicate_nodes[-2][:id]}-#{duplicate_nodes.last[:id]}"
        duplicate_nodes.last[:id] = new_node_id
        @node_ids[new_node_id] = duplicate_nodes
      end

      dom_id = "#{nodes[-2][:id]}-#{dom_id}"
    end

    @node_ids[dom_id] = nodes
    dom_id
  end

  def dom_id_text(text)
    text.downcase.gsub(/\?/, '-questionmark').gsub(/!/, '-bang').gsub(/[^a-z0-9]+/, ' ')
    .strip.gsub(/\s+/, '-')
  end

  def engine
    @engine ||= Redcarpet::Markdown.new(Renderer, {
        no_intra_emphasis: true,
        fenced_code_blocks: true,
        autolink: true,
        strikethrough: true,
        superscript: true,
        tables: true
    })
  end

  def extract_raw_header_and_body
    if @raw_body =~ /^\-{40,}$/
      @raw_header, _, @raw_body = @raw_body.partition(/^\-{40,}$/).map(&:strip)
    end
  end

  def generate_body
    @body = engine.render(@raw_body)
  end

  def generate_header
    @header = engine.render(@raw_header).html_safe
  end

  def generate_structure
    @headings_for_index = []
    if @body.present?
      @body = Nokogiri::HTML(@body).tap do |doc|
        hierarchy = []

        doc.at('body').children.each do |node|
          if node.name =~ /^h[3-6]$/
            case node.name
              when 'h3'
                hierarchy = [node]
                @headings_for_index << [1, node, node.inner_html]
              when 'h4'
                hierarchy = hierarchy[0, 1] + [node]
                @headings_for_index << [2, node, node.inner_html]
              when 'h5'
                hierarchy = hierarchy[0, 2] + [node]
              when 'h6'
                hierarchy = hierarchy[0, 3] + [node]
            end

            node[:id] = dom_id(hierarchy)
            node.inner_html = "#{node_index(hierarchy)} #{node.inner_html}"
          end
        end
      end.to_html
    end
  end

  def generate_index
    if @headings_for_index.present?
      raw_index = ''
      @headings_for_index.each do |level, node, label|
        if level == 1
          raw_index += "1. [#{label}](##{node[:id]})\n"
        elsif level == 2
          raw_index += "    * [#{label}](##{node[:id]})\n"
        end
      end

      @index = Nokogiri::HTML(engine.render(raw_index)).tap do |doc|
        doc.at('ol')[:class] = 'chapters'
      end.to_html

      @index = <<-INDEX.html_safe
          <div id="subCol">
            <h3 class="chapter"><img src="images/chapters_icon.gif" alt="" />Chapters</h3>
            #{@index}
          </div>
      INDEX
    end
  end

  def generate_title
    if heading = Nokogiri::HTML(@header).at(:h2)
      @title = "#{heading.text} — Ruby on Rails Guides".html_safe
    else
      @title = "Ruby on Rails Guides"
    end
  end

  def node_index(hierarchy)
    case hierarchy.size
      when 1
        @index_counter[2] = @index_counter[3] = @index_counter[4] = 0
        "#{@index_counter[1] += 1}"
      when 2
        @index_counter[3] = @index_counter[4] = 0
        "#{@index_counter[1]}.#{@index_counter[2] += 1}"
      when 3
        @index_counter[4] = 0
        "#{@index_counter[1]}.#{@index_counter[2]}.#{@index_counter[3] += 1}"
      when 4
        "#{@index_counter[1]}.#{@index_counter[2]}.#{@index_counter[3]}.#{@index_counter[4] += 1}"
    end
  end

  def render_page
    @view.content_for(:header_section) { @header }
    @view.content_for(:page_title) { @title }
    @view.content_for(:index_section) { @index }
    @view.render(:layout => @layout, :text => @body)
  end
end