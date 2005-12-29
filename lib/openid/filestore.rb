require 'fileutils'
require 'pathname'
require 'tempfile'

require 'openid/util'
require 'openid/stores'

# Filesystem-based store for OpenID associations and nonces.
#
# Methods of this object may raise SystemCallError if filestystem
# related errors are encountered.


module OpenID

  class FilesystemOpenIDStore < OpenIDStore
  
    @@FILENAME_ALLOWED = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-".split("")
  
    # Init the store, putting all data in directory

    def initialize(directory)
      p_dir = Pathname.new(directory)
      @nonce_dir = p_dir.join('nonces')
      @association_dir = p_dir.join('associations')
      @temp_dir = p_dir.join('temp')
      @auth_key_name = p_dir.join('auth_key')
      @max_nonce_age = 6 * 60 * 60
      
      self.ensureDir(@nonce_dir)
      self.ensureDir(@association_dir)
      self.ensureDir(@temp_dir)
      self.ensureDir(File.dirname(@auth_key_name))
    end

    # Read the auth key from the auth key file. Returns nil if there
    # is currently no auth key.

    def readAuthKey
      f = nil
      begin
        f = File.open(@auth_key_name)      
      rescue Errno::ENOENT
        return nil
      else
        return f.read
      ensure
        f.close unless f.nil?      
      end
    end

    # Generate a new random auth key and safely store it in the location
    # specified by @auth_key_name

    def createAuthKey
      auth_key = OpenID::Util.randomString(@@AUTH_KEY_LEN)
      f, tmp = mktemp
      begin
        begin
          f.write(auth_key)
          f.fsync
        ensure
          f.close
        end
        begin
          File.link(tmp, @auth_key_name)
        rescue Errno::EEXIST
          raise if readAuthKey.nil?
        end      
      ensure
        self.removeIfPresent(tmp)
      end

      auth_key
    end
    
    # Retrieve the auth key from the file specified by
    # @auth_key_file, creating it if it does not exist

    def getAuthKey
      auth_key = readAuthKey
      if auth_key.nil?
        auth_key = createAuthKey
      end
      
      if auth_key.length != @@AUTH_KEY_LEN
        raise StandardError.new("Bad auth key - wrong length")
      end
      
      auth_key
    end

    # Create a unique filename for a given server url and handle. The
    # filename that is returned will contain the domain name from the
    # server URL for ease of human inspection of the data dir.

    def getAssociationFilename(server_url)
      filename = self.filenameFromURL(server_url)
      @association_dir.join(filename)
    end

    # Store an association in the assoc directory

    def storeAssociation(association)
      assoc_s = OpenID::ConsumerAssociation.serialize(association)
      filename = getAssociationFilename(association.server_url)
      f, tmp = mktemp
    
      begin
        begin
          f.write(assoc_s)
          f.fsync
        ensure
          f.close
        end
        
        begin
          File.rename(tmp, filename)
        rescue Errno::EEXIST
        
          begin
            File.unlink(filename)
          rescue Errno::ENOENT
            # do nothing
          end
          
          File.rename(tmp, filename)
        end
        
      rescue
        self.removeIfPresent(tmp)
        raise
      end
    end
    
    # Retrieve an association
    
    def getAssociation(server_url)
      filename = getAssociationFilename(server_url)
      begin
        assoc_file = File.open(filename, "r")
      rescue Errno::ENOENT
        return nil
      else
        begin
          assoc_s = assoc_file.read
        ensure
          assoc_file.close
        end
        
        begin
          association = OpenID::ConsumerAssociation.deserialize(assoc_s)      
        rescue "VersionError"
          self.removeIfPresent(filename)
          return nil
        end

        # clean up expired associations
        if association.expiresIn == 0
          self.removeIfPresent(filename)
          return nil
        else
          return association
        end
      end
      
    end

    # Remove an association if it exists, otherwise do nothing.
    
    def removeAssociation(server_url, handle)
      assoc = getAssociation(server_url)
      if assoc.nil? or assoc.handle != handle
        false
      else
        filename = getAssociationFilename(server_url)
        self.removeIfPresent(filename)
      end
    end

    # Mark this nonce as present
    
    def storeNonce(nonce)
      filename = @nonce_dir.join(nonce)
      File.open(filename, "w").close
    end

    # Return whether this nonce is present.  As a side-effect, mark it 
    # as no longer present.

    def useNonce(nonce)
      filename = @nonce_dir.join(nonce)
      begin
        st = File.stat(filename)
      rescue Errno::ENOENT
        return false
      else
        begin
          File.unlink(filename)
        rescue Errno::ENOENT
          return false
        end      
        nonce_age = Time.now.to_f - st.mtime.to_f
        nonce_age <= @max_nonce_age
      end
    end

    # Garbage collection routine.  Clean up old associations and nonces.

    def clean
      nonces = Dir[@nonce_dir.join("*")]
      now = Time.now
      
      nonces.each do |nonce|
        filename = nonce_dir.join(nonce)
        begin
          st = File.stat(filename)
        rescue Errno::ENOENT
          next
        else
          nonce_age = now - st.mtime
          self.removeIfPresent(filename) if nonce_age > @max_nonce_age
        end
      end

      association_filenames = Dir[@association_dir.join("*")]
      association_filenames.each do |af|
        begin
          f = File.open(af, 'r')
        rescue Errno::ENOENT
          next
        else
          begin
            assoc_s = f.read
          ensure
            f.close
          end
          begin
            association = OpenID::ConsumerAssociation.deserialize(assoc_s)
          rescue "VersionError"
            self.removeIfPresent(af)
            next
          else
            self.removeIfPresent(af) if association.getExpiresIn == 0          
          end
        end
      end
    end

    protected

    # Create a temporary file and return the File object and filename.
    
    def mktemp
      f = Tempfile.new('tmp', @temp_dir)
      [f, f.path]
    end

    # create a safe filename from a url
    def filenameFromURL(url)
      filename = []
      url.sub('://','-').split("").each do |c|
        if @@FILENAME_ALLOWED.index(c)
          filename << c
        else
          filename << sprintf("_%02X", c[0])
        end    
      end
      filename.join("")
    end

    # remove file if present in filesystem

    def removeIfPresent(filename)
      begin
        File.unlink(filename)
      rescue Errno::ENOENT
        return false
      end
      return true
    end
  
    # ensure that a path exists

    def ensureDir(dir_name)
      FileUtils::mkdir_p(dir_name)
    end
    
  end

end


